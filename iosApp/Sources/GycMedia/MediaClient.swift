import AVFoundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import os.log

enum CaptureImageFileError: Error { case encoding, writing }

/** 系统图片选择、拍照与相册写入；单次 Picker 的回调由请求 ID 隔离。 */
public final class MediaClient: NSObject {
    // 与 common ImageContentPolicy 一致；系统选择器回传后立即检查，压缩不绕过原始编码限额。
    static let maxBytes = 32 * 1024 * 1024
    static let limitExceededMessage = "图片数据超过 32 MiB 限额"
    /// 系统相机/相册一次只能展示一个，进程内复用同一 Bridge 并以请求 ID 隔离迟到回调。
    public static let shared = MediaClient()

    /// 多前台窗口或自定义容器由宿主返回所属页面；在主线程配置，返回 nil 表示当前无法展示。
    public var presenterResolver: (() -> UIViewController?)?

    private struct PickerRequest {
        let id: UUID
        let callback: MediaPickerCallback?
        let compression: ImageSelectionPolicy?
        var fileRequest: MediaFilePickerRequest? = nil
        var fileCompletion: ((MediaFilePickerResult) -> Void)? = nil
        var presenter: UIViewController? = nil
        var ownedFiles: [URL] = []
    }

    private var deliveredFiles: [UUID: [URL]] = [:]
    private var fileExport: AVAssetExportSession?
    private var pickerRequest: PickerRequest?
    private var latestPickerRequestId: UUID?
    private var pickerController: UIViewController?
    private var imageReadProgress: Progress?
    /// 多次替换只保留最新展示动作，旧 dismiss 完成后再执行。
    private var pendingPresentation: (() -> Void)?
    private var isDismissingPicker = false
    private var isPresentingPicker = false
    private var pendingDismissal: (() -> Void)?

    private override init() {
        super.init()
    }

    /// 根据来源展示系统相机或 Photos Picker，并替换任何尚未结束的旧请求。
    public func pickImages(
        source: Int32,
        maxCount: Int32,
        maxDimension: Int32,
        jpegQuality: Int32,
        callback: MediaPickerCallback
    ) {
        UIKitExecutionContext.run { [weak self] in
            guard let self else { return }
            guard source == 0 || source == 1, maxCount > 0, maxCount <= 500,
                  maxDimension >= 0, maxDimension == 0 || (jpegQuality >= 1 && jpegQuality <= 100) else {
                callback.onFailed(message: "Invalid media request")
                return
            }
            var options = MediaFilePickerRequest(acceptTypes: ["image/*"], multiple: source == 1 && maxCount > 1, capture: source == 0, maxFiles: Int(maxCount), maxBytes: Self.maxBytes)
            options.prefersCurrentRepresentation = true
            options.maxTotalBytes = Self.maxBytes
            options.captureJPEGQuality = 1
            var request = PickerRequest(id: UUID(), callback: callback,
                compression: maxDimension > 0 && jpegQuality > 0 ? ImageSelectionPolicy(maxDimension: CGFloat(maxDimension), quality: CGFloat(jpegQuality) / 100) : nil)
            request.fileRequest = options
            self.beginFileSelection(request)

        }
    }

    private func presentPendingPickerIfReady() {
        guard !isDismissingPicker else { return }
        let presentation = pendingPresentation
        pendingPresentation = nil
        presentation?()
    }

    private func presentPicker(_ picker: UIViewController, requestId: UUID, canRetry: Bool = true) {
        guard pickerRequest?.id == requestId else { return }
        let presenter: UIViewController?
        if let requested = pickerRequest?.presenter {
            presenter = UIKitPresentationContext.topViewController(from: requested)
        } else if let resolver = presenterResolver {
            presenter = UIKitPresentationContext.topViewController(from: resolver())
        } else {
            presenter = UIKitPresentationContext.topViewController()
        }
        guard let presenter else {
            finishPicker(error: "无法获取当前页面")
            return
        }
        let retry = { (canRetry: Bool) in
            DispatchQueue.main.async { self.presentPicker(picker, requestId: requestId, canRetry: canRetry) }
        }
        if let coordinator = presenter.transitionCoordinator {
            if coordinator.animate(alongsideTransition: nil, completion: { _ in retry(true) }) { return }
            if canRetry { retry(false); return }
        }
        guard let view = presenter.viewIfLoaded, view.window != nil, !view.isHidden, view.alpha > 0 else {
            finishPicker(error: "当前页面不可见")
            return
        }
        if presenter.isBeingPresented || presenter.isBeingDismissed {
            if canRetry { retry(false) } else { finishPicker(error: "当前页面正在转场") }
            return
        }
        pickerController = picker
        isPresentingPicker = true
        // PHPicker 可能先排队、尚未建立 UIKit 转场属性；等 present completion 后再关闭旧请求。
        presenter.present(picker, animated: true) {
            self.isPresentingPicker = false
            let dismissal = self.pendingDismissal
            self.pendingDismissal = nil
            dismissal?()
        }
    }

    /// 旧图片桥没有 request ID，迟到 dispose 只能取消图片请求，不能撤销新的文件选择。
    public func cancelImagePicker() {
        UIKitExecutionContext.run { [weak self] in
            guard let self, self.pickerRequest?.callback != nil else { return }
            self.cancelCurrentPicker()
        }
    }

    private func cancelCurrentPicker() { finishFilePicker(.cancelled) }

    /// 按 Photos 的仅添加权限写入系统相册，不读取用户已有照片。
    public func saveImage(data: Data, fileNamePrefix: String, callback: MediaSaveCallback) {
        UIKitExecutionContext.run { [weak self] in
            guard let self else { return }
            guard data.count <= Self.maxBytes, Self.isValidImageForSave(data) else {
                callback.onInvalidContent()
                return
            }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                writeImageToPhotoLibrary(data: data, fileNamePrefix: fileNamePrefix, callback: callback)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                    guard self != nil else { return }
                    UIKitExecutionContext.run {
                        guard let self else { return }
                        switch newStatus {
                        case .authorized, .limited:
                            self.writeImageToPhotoLibrary(
                                data: data,
                                fileNamePrefix: fileNamePrefix,
                                callback: callback
                            )
                        case .denied:
                            callback.onPermissionDenied()
                        case .restricted:
                            callback.onPermissionRestricted()
                        case .notDetermined:
                            callback.onFailed(message: "无法确认相册权限状态")
                        @unknown default:
                            callback.onFailed(message: "无法确认相册权限状态")
                        }
                    }
                }
            case .denied:
                callback.onPermissionBlocked()
            case .restricted:
                callback.onPermissionRestricted()
            @unknown default:
                callback.onFailed(message: "无法确认相册权限状态")
            }
        }
    }

    /// dismiss 系统页面后逐张回传结果，最后发送唯一完成事件。
    private func completePicker(_ images: [SelectedImage]) {
        finishPicker { callback in
            images.forEach { image in
                callback.onImage(
                    data: image.data,
                    fileName: image.fileName,
                    contentType: image.contentType
                )
            }
            callback.onCompleted()
        }
    }

    /// 区分本次刚拒绝与此前已阻止；只有后者允许 shared 展示设置页恢复入口。
    private func denyPickerPermission(blocked: Bool = false, restricted: Bool = false, permission: MediaCapturePermission = .camera) {
        finishFilePicker(restricted ? .permissionRestricted(permission) : blocked ? .permissionBlocked(permission) : .permissionDenied(permission))
    }

    private func finishPicker(error: String) { finishFilePicker(.failed(error)) }

    /// 结束当前请求并在清空状态后交付唯一终态回调。
    private func finishPicker(_ completion: @escaping (MediaPickerCallback) -> Void) {
        finishRequest { request in if let callback = request.callback { completion(callback) } }
    }

    private func finishRequest(preserveFiles: Bool = false, _ completion: @escaping (PickerRequest) -> Void) {
        UIKitExecutionContext.run { [weak self] in
            guard let self, let request = pickerRequest else { return }
            if !preserveFiles {
                request.ownedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
                releaseFiles(token: request.id)
            }
            imageReadProgress?.cancel()
            imageReadProgress = nil
            fileExport?.cancelExport(); fileExport = nil
            let controller = pickerController
            pickerController = nil
            pickerRequest = nil
            pendingPresentation = nil
            if let controller {
                isDismissingPicker = true
                let dismiss = {
                    UIKitPresentationContext.dismiss(controller, animated: true) {
                        self.isDismissingPicker = false
                        completion(request)
                        self.presentPendingPickerIfReady()
                    }
                }
                if isPresentingPicker { pendingDismissal = dismiss } else { dismiss() }
            } else {
                completion(request)
            }
        }
    }

    /** 系统拍照与共享扫码权限语义保持一致；拒绝后不再尝试展示无权限的相机控制器。 */
    private func requestCameraAccess(requestId: UUID) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentCamera(requestId: requestId)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                UIKitExecutionContext.run {
                    guard self.pickerRequest?.id == requestId else { return }
                    guard granted else {
                        self.denyPickerPermission(restricted: false)
                        return
                    }
                    self.presentCamera(requestId: requestId)
                }
            }
        case .denied:
            denyPickerPermission(blocked: true)
        case .restricted:
            denyPickerPermission(restricted: true)
        @unknown default:
            finishPicker(error: "无法确认相机权限状态")
        }
    }

    /// 授权回调必须匹配当前请求 ID，旧请求不能拉起新的相机页面。
    private func presentCamera(requestId: UUID) {
        guard let request = pickerRequest, request.id == requestId else { return }
        if let options = request.fileRequest, options.captureVideo, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            requestAudioAccess(requestId: requestId)
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = request.fileRequest?.captureTypes ?? [UTType.image.identifier]
        picker.videoMaximumDuration = 60
        picker.delegate = self
        presentPicker(picker, requestId: requestId)
    }

    // ImageIO 也可返回部分 PNG；先校验常见格式的结束边界，再小尺寸实际解码。
    // 这是保存入口的内容验证，不重新编码原图，也不声称验证所有编码细节。
    static func isValidImageForSave(_ data: Data) -> Bool {
        guard hasCompleteImageContainer(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) != nil
    }

    private static func hasCompleteImageContainer(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let size = bytes.count
            if size >= 8 && bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71 {
                var offset = 8
                while offset <= size - 12 {
                    let length = (0..<4).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
                    if length > UInt64(size - offset - 12) { return false }
                    if bytes[offset + 4] == 73 && bytes[offset + 5] == 69 && bytes[offset + 6] == 78 && bytes[offset + 7] == 68 {
                        return length == 0
                    }
                    offset += Int(length) + 12
                }
                return false
            }
            if size >= 3 && bytes[0] == 255 && bytes[1] == 216 {
                // Motion Photo 等合法 JPEG 可在 EOI 后附加数据，不能要求文件恰好结束。
                var offset = 2
                while offset < size - 1 {
                    let value = bytes[offset]
                    offset += 1
                    if value != 255 { continue }
                    while offset < size && bytes[offset] == 255 { offset += 1 }
                    if offset >= size { return false }
                    let marker = bytes[offset]
                    offset += 1
                    if marker == 217 { return true }
                    if marker == 0 || marker == 1 || marker == 216 || (208...215).contains(marker) { continue }
                    if offset > size - 2 { return false }
                    let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
                    if length < 2 || length > size - offset { return false }
                    offset += length
                }
                return false
            }
            if size >= 12 && bytes[0] == 82 && bytes[1] == 73 && bytes[2] == 70 && bytes[3] == 70 &&
                bytes[8] == 87 && bytes[9] == 69 && bytes[10] == 66 && bytes[11] == 80 {
                let declared = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(bytes[4 + $1]) << (8 * $1)) }
                return declared >= 4 && declared + 8 <= UInt64(size)
            }
            // 其他原来受 ImageIO 支持的格式仍交给系统实际解码。
            return true
        }
    }

    /// 使用原始编码写入照片库，避免把二维码重新压缩后降低识别清晰度。
    private func writeImageToPhotoLibrary(
        data: Data,
        fileNamePrefix: String,
        callback: MediaSaveCallback
    ) {
        let safePrefix = fileNamePrefix
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let name = safePrefix.isEmpty ? "image" : safePrefix
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let fileExtension = UTType(identifier as String)?.preferredFilenameExtension else {
            callback.onInvalidContent()
            return
        }
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = "\(name)_\(Int(Date().timeIntervalSince1970 * 1000)).\(fileExtension)"
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: options)
        } completionHandler: { [weak self] saved, error in
            guard self != nil else { return }
            UIKitExecutionContext.run {
                if saved {
                    callback.onSaved()
                } else {
                    callback.onFailed(message: error?.localizedDescription ?? "保存图片失败")
                }
            }
        }
    }
}

extension MediaClient: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// 用户取消相机时以空结果正常完成，不伪装成读取失败。
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard pickerController === picker else { return }
        cancelCurrentPicker()
    }

    /// 优先读取系统提供的原始文件；拍照无 URL 时回退到 UIImage JPEG 数据。
    public func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        guard pickerController === picker, let request = pickerRequest else { return }
        guard let options = request.fileRequest else { return }
        var retained: MediaSelectedFile?
        if options.prefersCurrentRepresentation, let source = info[.imageURL] as? URL {
            do {
                retained = try Self.copySelectedFile(source, suggestedName: nil, options: options)
            } catch ImageSelectionError.tooLarge { finishPicker(error: Self.limitExceededMessage); return }
            catch { /* 旧图片 API 在原始 URL 不可读时仍允许 UIImage 编码回退。 */ }
        }
        if info[.mediaType] as? String == UTType.movie.identifier {
            guard let source = info[.mediaURL] as? URL else { finishPicker(error: "Invalid captured movie"); return }
            do {
                retained = try Self.copySelectedFile(source, suggestedName: nil, options: MediaFilePickerRequest(acceptTypes: ["video/*"], multiple: false, capture: true, maxBytes: options.maxBytes))
            } catch { finishPicker(error: Self.captureFailureMessage(error, legacyImage: request.callback != nil)); return }
        }
        if let retained { pickerRequest?.ownedFiles.append(retained.url) }
        let retainedFile = retained
        dismissFilePickerBeforeReading(requestId: request.id) { self.readCapturedFile(info, retained: retainedFile, request: request) }

    }
}

extension MediaClient: PHPickerViewControllerDelegate {
    /// Read one provider at a time; a cancelled/replaced request cannot start another file.
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard pickerController === picker, let request = pickerRequest else { return }
        guard !results.isEmpty else { cancelCurrentPicker(); return }
        finishPhotoFileSelection(picker, providers: results.map(\.itemProvider))
    }
}

extension MediaClient {
    /// 与旧选图共用一个系统 Picker owner；取消句柄仅结束所属请求。
    @discardableResult
    public func pickFiles(_ options: MediaFilePickerRequest, presenter: UIViewController?, completion: @escaping (MediaFilePickerResult) -> Void) -> UUID {
        let id = UUID()
        UIKitExecutionContext.run { [weak self] in
            guard let self else { return }
            var request = PickerRequest(id: id, callback: nil, compression: nil)
            request.fileRequest = options; request.fileCompletion = completion; request.presenter = presenter
            self.beginFileSelection(request)

        }
        return id
    }

    private func tracePicker(_ branch: String, options: MediaFilePickerRequest) {
#if DEBUG
        let types = options.types
        os_log("[MediaFileSelection] branch=%{public}@ empty=%{public}d image=%{public}d video=%{public}d document=%{public}d unknown=%{public}d", log: .default, type: .info, branch as NSString,
              options.acceptTypes.flatMap { $0.components(separatedBy: ",") }.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? 1 : 0, options.selectionTypes.filter { $0.conforms(to: .image) }.count,
              options.selectionTypes.filter { $0.conforms(to: .movie) }.count,
              types.filter { !$0.conforms(to: .image) && !$0.conforms(to: .movie) && !$0.isDynamic }.count,
              types.filter { $0.isDynamic }.count)
#endif
    }

    private func beginFileSelection(_ request: PickerRequest) {
        guard let options = request.fileRequest, options.maxFiles > 0, options.maxFiles <= 500, options.maxBytes > 0,
              options.maxBytes <= 50 * 1024 * 1024, options.acceptTypes.count <= 32 else {
            request.callback?.onFailed(message: "Invalid file selection request"); request.fileCompletion?(.failed("Invalid file selection request")); return
        }
        let id = request.id
        latestPickerRequestId = id
        cancelCurrentPicker()
        guard latestPickerRequestId == id else { request.callback?.onCancelled(); request.fileCompletion?(.cancelled); return }
        pickerRequest = request
        pendingPresentation = { [weak self] in
            guard let self, self.pickerRequest?.id == id else { return }
            if options.capture {
                self.tracePicker("camera", options: options)
                guard options.captureImage != options.captureVideo, UIImagePickerController.isSourceTypeAvailable(.camera),
                      options.captureTypes.allSatisfy({ UIImagePickerController.availableMediaTypes(for: .camera)?.contains($0) == true }),
                      Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil,
                      !options.captureVideo || Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { self.finishPicker(error: "Camera capture unavailable"); return }
                if options.captureVideo {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .denied: self.denyPickerPermission(blocked: true, permission: .microphone); return
                    case .restricted: self.denyPickerPermission(restricted: true, permission: .microphone); return
                    default: break
                    }
                }
                self.requestCameraAccess(requestId: id)
            } else if options.mediaOnly {
                self.tracePicker(options.image && options.video ? "PhotosUI.mixed" : options.image ? "PhotosUI.images" : "PhotosUI.videos", options: options)
                var configuration = PHPickerConfiguration()
                configuration.filter = options.image && options.video ? .any(of: [.images, .videos]) : options.image ? .images : .videos
                configuration.selectionLimit = options.multiple ? options.maxFiles : 1
                configuration.preferredAssetRepresentationMode = options.prefersCurrentRepresentation ? .current : .compatible
                let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
                self.presentPicker(picker, requestId: id)
            } else {
                self.tracePicker("DocumentPicker", options: options)
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: options.types, asCopy: true)
                picker.allowsMultipleSelection = options.multiple; picker.delegate = self
                self.presentPicker(picker, requestId: id)
            }
        }
        presentPendingPickerIfReady()
    }

    public func cancelFiles(requestId: UUID) {
        UIKitExecutionContext.run { [weak self] in
            guard self?.pickerRequest?.id == requestId else { return }
            self?.cancelCurrentPicker()
        }
    }

    public func releaseFiles(token: UUID) {
        UIKitExecutionContext.run { [weak self] in
            self?.deliveredFiles.removeValue(forKey: token)?.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func finishFilePicker(_ result: MediaFilePickerResult) {
        let preserve: Bool
        if case .selected = result { preserve = true } else { preserve = false }
        finishRequest(preserveFiles: preserve) { request in
            if let callback = request.callback {
                switch result {
                case .cancelled: callback.onCancelled()
                case .permissionDenied: callback.onPermissionDenied()
                case .permissionBlocked: callback.onPermissionBlocked()
                case .permissionRestricted: callback.onPermissionRestricted()
                case .failed(let message): callback.onFailed(message: message)
                case .selected: preconditionFailure("Legacy bytes must adapt the selected lease before completion")
                }
            } else { request.fileCompletion?(result) }
        }
    }

    private func completeFilePicker(_ files: [MediaSelectedFile], requestId: UUID) {
        guard pickerRequest?.id == requestId else { return }
        let selected = files.map(\.url)
        pickerRequest?.ownedFiles.filter { !selected.contains($0) }.forEach { try? FileManager.default.removeItem(at: $0) }
        pickerRequest?.ownedFiles = selected
        deliveredFiles[requestId] = selected
        if let request = pickerRequest, request.callback != nil {
            pickerRequest?.ownedFiles = []
            adaptSelectedImages(files, request: request)
        } else { finishFilePicker(.selected(token: requestId, files: files)) }
    }

    /// 旧图片 API 仅适配同一次原始文件选择结果；取消、lease 和原生 UI 都复用文件流程。
    private func adaptSelectedImages(_ files: [MediaSelectedFile], request: PickerRequest) {
        guard !files.isEmpty else { finishPicker(error: "无法读取所选图片"); return }
        let providers = files.map { file -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = file.fileName
            let type = UTType(mimeType: file.contentType) ?? UTType(filenameExtension: file.url.pathExtension) ?? .image
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .ownProcess) { completion in completion(file.url, false, nil); return nil }
            return provider
        }
        imageReadProgress = ImageSelectionProcessor.readImages(providers, policy: request.compression,
            isActive: { [weak self] in self?.pickerRequest?.id == request.id }) { [weak self] result in
            guard let self, self.pickerRequest?.id == request.id else { return }
            switch result {
            case .failure(.tooLarge): self.finishPicker(error: Self.limitExceededMessage)
            case .success(let images):
                if images.isEmpty { self.finishPicker(error: "无法读取所选图片") }
                else { self.completePicker(images) }
            }
        }
    }

    private func requestAudioAccess(requestId: UUID) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: presentCamera(requestId: requestId)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                UIKitExecutionContext.run {
                    guard let self, self.pickerRequest?.id == requestId else { return }
                    if granted { self.presentCamera(requestId: requestId) }
                    else { self.denyPickerPermission(permission: .microphone) }
                }
            }
        case .denied: denyPickerPermission(blocked: true, permission: .microphone)
        case .restricted: denyPickerPermission(restricted: true, permission: .microphone)
        @unknown default: finishPicker(error: "Unknown microphone permission")
        }
    }

    private func dismissFilePickerBeforeReading(requestId: UUID, read: @escaping () -> Void) {
        guard pickerRequest?.id == requestId else { return }
        let controller = pickerController; pickerController = nil
        guard let controller else { return }
        isDismissingPicker = true
        let dismiss = { [weak self] in
            UIKitPresentationContext.dismiss(controller, animated: true) {
                guard let self else { return }
                self.isDismissingPicker = false
                if self.pickerRequest?.id == requestId { read() }
                self.presentPendingPickerIfReady()
            }
        }
        if isPresentingPicker { pendingDismissal = dismiss } else { dismiss() }
    }

    private static func selectedFileMetadata(_ source: URL, suggestedName: String?, options: MediaFilePickerRequest, remainingBytes: Int? = nil) throws -> MediaSelectedFile {
        var current = source
        current.removeAllCachedResourceValues()
        let values = try current.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        let limit = min(options.maxBytes, remainingBytes ?? options.maxBytes)
        if let size = values.fileSize, size > limit { throw ImageSelectionError.tooLarge }
        guard source.isFileURL, values.isRegularFile == true, let size = values.fileSize, size > 0,
              options.accepts(values.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data) else { throw CocoaError(.fileReadCorruptFile) }
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        return MediaSelectedFile(url: source, fileName: suggestedName ?? source.lastPathComponent, contentType: type.preferredMIMEType ?? "application/octet-stream", size: size)
    }

    private static func copySelectedFile(_ source: URL, suggestedName: String?, options: MediaFilePickerRequest, remainingBytes: Int? = nil) throws -> MediaSelectedFile {
        let original = try selectedFileMetadata(source, suggestedName: suggestedName, options: options, remainingBytes: remainingBytes)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = source.pathExtension.isEmpty ? base : base.appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return try selectedFileMetadata(target, suggestedName: original.fileName, options: options, remainingBytes: remainingBytes)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    // PHPickerResult 没有公开构造入口；单独保留系统结果到 provider 的薄边界供真实 IO 回归。
    func finishPhotoFileSelection(_ picker: PHPickerViewController, providers: [NSItemProvider]) {
        guard pickerController === picker, let request = pickerRequest, request.fileRequest != nil else { return }
        guard !providers.isEmpty else { cancelCurrentPicker(); return }
        dismissFilePickerBeforeReading(requestId: request.id) { self.readFileProviders(providers, requestId: request.id, files: []) }
    }

    private func readFileProviders(_ providers: [NSItemProvider], requestId: UUID, files: [MediaSelectedFile]) {
        guard let request = pickerRequest, request.id == requestId, let options = request.fileRequest else { return }
        guard providers.count + files.count <= (options.multiple ? options.maxFiles : 1) else { finishPicker(error: "Too many selected files"); return }
        guard let provider = providers.first else { completeFilePicker(files, requestId: requestId); return }
        guard let type = provider.registeredTypeIdentifiers.first(where: { id in
            guard let type = UTType(id) else { return false }
            return (type.conforms(to: .image) || type.conforms(to: .movie)) && options.accepts(type)
        }) else {
            if request.callback != nil { readFileProviders(Array(providers.dropFirst()), requestId: requestId, files: files) }
            else { finishPicker(error: "Unsupported selected media format") }
            return
        }
        let remaining = Array(providers.dropFirst())
        let budget = options.maxTotalBytes.map { $0 - files.reduce(0) { $0 + $1.size } }
        imageReadProgress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
            // Provider 的临时 URL 在回调返回后失效，复制必须在此完成。
            var copied: MediaSelectedFile?
            var tooLarge = false
            do { if error == nil, let url { copied = try Self.copySelectedFile(url, suggestedName: provider.suggestedName, options: options, remainingBytes: budget) } }
            catch ImageSelectionError.tooLarge { tooLarge = true }
            catch {}
            UIKitExecutionContext.run {
                guard let self, self.pickerRequest?.id == requestId else { if let copied { try? FileManager.default.removeItem(at: copied.url) }; return }
                self.imageReadProgress = nil
                if tooLarge { self.finishPicker(error: request.callback != nil ? Self.limitExceededMessage : "File exceeds selection size limit"); return }
                guard let copied else {
                    if request.callback != nil { self.readFileProviders(remaining, requestId: requestId, files: files) }
                    else { self.finishPicker(error: "Unable to read selected media") }
                    return
                }
                self.pickerRequest?.ownedFiles.append(copied.url)
                self.readFileProviders(remaining, requestId: requestId, files: files + [copied])
            }
        }
    }

    private func readDocumentFiles(_ urls: [URL], requestId: UUID) {
        guard let request = pickerRequest, request.id == requestId, let options = request.fileRequest else { return }
        guard !urls.isEmpty, urls.count <= (options.multiple ? options.maxFiles : 1) else { finishPicker(error: "Invalid selected files"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [MediaSelectedFile] = []
            do {
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    files.append(try Self.copySelectedFile(url, suggestedName: nil, options: options))
                }
            } catch { files.forEach { try? FileManager.default.removeItem(at: $0.url) }; files = [] }
            UIKitExecutionContext.run {
                guard self.pickerRequest?.id == requestId else { files.forEach { try? FileManager.default.removeItem(at: $0.url) }; return }
                guard !files.isEmpty else { self.finishPicker(error: "Unable to read selected files"); return }
                self.pickerRequest?.ownedFiles.append(contentsOf: files.map(\.url))
                self.completeFilePicker(files, requestId: requestId)
            }
        }
    }

    private static func captureFailureMessage(_ error: Error, legacyImage: Bool) -> String {
        if case ImageSelectionError.tooLarge = error { return legacyImage ? limitExceededMessage : "File exceeds selection size limit" }
        if case CaptureImageFileError.encoding = error { return "Unable to encode captured image" }
        if case CaptureImageFileError.writing = error { return "Unable to write captured image" }
        return "Invalid captured file output"
    }

    /// 只写入新编码的拍摄结果；已保全的 URL 直接复核 metadata，不再复制一次。
    static func writeCapturedImage(_ image: UIImage, options: MediaFilePickerRequest, to target: URL) throws -> MediaSelectedFile {
        let jpeg = options.accepts(.jpeg)
        guard let data = jpeg ? image.jpegData(compressionQuality: options.captureJPEGQuality) : image.pngData(), !data.isEmpty else { throw CaptureImageFileError.encoding }
        guard data.count <= options.maxBytes else { throw ImageSelectionError.tooLarge }
        do {
            do { try data.write(to: target, options: .atomic) } catch { throw CaptureImageFileError.writing }
            return try selectedFileMetadata(target, suggestedName: nil, options: options)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    private func readCapturedFile(_ info: [UIImagePickerController.InfoKey: Any], retained: MediaSelectedFile?, request: PickerRequest) {
        guard pickerRequest?.id == request.id, let options = request.fileRequest else { return }
        if let retained {
            // 保持 MP4-only 的 AVFoundation 验真/转码合同，不凭扩展名绕过原解析路径。
            if info[.mediaType] as? String == UTType.movie.identifier && !options.accepts(.quickTimeMovie) && options.accepts(.mpeg4Movie) {
                exportCapturedFile(retained.url, request: request)
                return
            }
            let type = UTType(mimeType: retained.contentType) ?? UTType(filenameExtension: retained.url.pathExtension) ?? .data
            if options.accepts(type) {
                do {
                    let file = try Self.selectedFileMetadata(retained.url, suggestedName: retained.fileName, options: options)
                    completeFilePicker([file], requestId: request.id)
                } catch { finishPicker(error: Self.captureFailureMessage(error, legacyImage: request.callback != nil)) }
            } else { finishPicker(error: "Unsupported captured file format") }
            return
        }
        guard info[.mediaType] as? String == UTType.image.identifier, let image = info[.originalImage] as? UIImage else { finishPicker(error: "Invalid captured image"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(options.accepts(.jpeg) ? "jpg" : "png")
            let result = Result { try Self.writeCapturedImage(image, options: options, to: target) }
            UIKitExecutionContext.run {
                guard self.pickerRequest?.id == request.id else { try? FileManager.default.removeItem(at: target); return }
                switch result {
                case .success(let file):
                    self.pickerRequest?.ownedFiles.append(file.url)
                    self.completeFilePicker([file], requestId: request.id)
                case .failure(let error): self.finishPicker(error: Self.captureFailureMessage(error, legacyImage: request.callback != nil))
                }
            }
        }
    }

    private func exportCapturedFile(_ source: URL, request: PickerRequest) {
        guard let options = request.fileRequest, let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= options.maxBytes,
              let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHighestQuality), export.supportedFileTypes.contains(.mp4) else { finishPicker(error: "Unable to export captured movie"); return }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        pickerRequest?.ownedFiles.append(target); fileExport = export
        export.outputURL = target; export.outputFileType = .mp4
        export.exportAsynchronously { [weak self] in
            UIKitExecutionContext.run {
                guard let self, self.pickerRequest?.id == request.id else { try? FileManager.default.removeItem(at: target); return }
                guard export.status == .completed else { try? FileManager.default.removeItem(at: target); self.finishPicker(error: "Unable to export captured movie"); return }
                self.fileExport = nil
                do {
                    let file = try Self.selectedFileMetadata(target, suggestedName: nil, options: options)
                    self.completeFilePicker([file], requestId: request.id)
                } catch { self.finishPicker(error: Self.captureFailureMessage(error, legacyImage: request.callback != nil)) }
            }
        }
    }
}

extension MediaClient: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard pickerController === controller, let request = pickerRequest, request.fileRequest != nil else { return }
        dismissFilePickerBeforeReading(requestId: request.id) { self.readDocumentFiles(urls, requestId: request.id) }
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard pickerController === controller else { return }
        cancelCurrentPicker()
    }
}
