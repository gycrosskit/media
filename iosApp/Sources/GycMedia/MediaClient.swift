import AVFoundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

/** 系统图片选择、拍照与相册写入；单次 Picker 的回调由请求 ID 隔离。 */
public final class MediaClient: NSObject {
    /// 系统相机/相册一次只能展示一个，进程内复用同一 Bridge 并以请求 ID 隔离迟到回调。
    public static let shared = MediaClient()

    /// 多前台窗口或自定义容器由宿主返回所属页面；在主线程配置，返回 nil 表示当前无法展示。
    public var presenterResolver: (() -> UIViewController?)?

    private struct PickerRequest {
        let id = UUID()
        let callback: MediaPickerCallback
        let compression: ImageSelectionPolicy?
    }

    private var pickerRequest: PickerRequest?
    private var latestPickerRequestId: UUID?
    private var pickerController: UIViewController?
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
            let request = PickerRequest(
                callback: callback,
                compression: maxDimension > 0 && jpegQuality > 0
                    ? ImageSelectionPolicy(
                        maxDimension: CGFloat(maxDimension),
                        quality: CGFloat(jpegQuality) / 100.0
                    )
                    : nil
            )
            latestPickerRequestId = request.id
            cancelImagePicker()
            // 旧终态回调可能同步发起新请求；重入的新请求拥有展示权。
            guard latestPickerRequestId == request.id else {
                callback.onCancelled()
                return
            }
            pickerRequest = request
            pendingPresentation = { [weak self] in
                guard let self, self.pickerRequest?.id == request.id else { return }
                if source == 0 {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        self.finishPicker(error: "当前设备不支持相机")
                        return
                    }
                    self.requestCameraAccess(requestId: request.id)
                    return
                }
                var configuration = PHPickerConfiguration(photoLibrary: .shared())
                configuration.filter = .images
                configuration.selectionLimit = max(1, Int(maxCount))
                configuration.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                self.presentPicker(picker, requestId: request.id)
            }
            presentPendingPickerIfReady()
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
        if let resolver = presenterResolver {
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

    /// 取消当前系统 Picker 并清空所有请求状态；重复调用保持幂等。
    public func cancelImagePicker() {
        finishPicker { callback in callback.onCancelled() }
    }

    /// 按 Photos 的仅添加权限写入系统相册，不读取用户已有照片。
    public func saveImage(data: Data, fileNamePrefix: String, callback: MediaSaveCallback) {
        UIKitExecutionContext.run { [weak self] in
            guard let self else { return }
            guard UIImage(data: data) != nil else {
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
    private func denyPickerPermission(blocked: Bool = false, restricted: Bool = false) {
        finishPicker { callback in
            if restricted {
                callback.onPermissionRestricted()
            } else if blocked {
                callback.onPermissionBlocked()
            } else {
                callback.onPermissionDenied()
            }
        }
    }

    /// dismiss 系统页面后发送唯一失败事件，并清空当前请求。
    private func finishPicker(error: String) {
        finishPicker { callback in callback.onFailed(message: error) }
    }

    /// 结束当前请求并在清空状态后交付唯一终态回调。
    private func finishPicker(_ completion: @escaping (MediaPickerCallback) -> Void) {
        UIKitExecutionContext.run { [weak self] in
            guard let self, let request = pickerRequest else { return }
            let controller = pickerController
            pickerController = nil
            pickerRequest = nil
            pendingPresentation = nil
            if let controller {
                isDismissingPicker = true
                let dismiss = {
                    UIKitPresentationContext.dismiss(controller, animated: true) {
                        self.isDismissingPicker = false
                        completion(request.callback)
                        self.presentPendingPickerIfReady()
                    }
                }
                if isPresentingPicker { pendingDismissal = dismiss } else { dismiss() }
            } else {
                completion(request.callback)
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
        guard pickerRequest?.id == requestId else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        presentPicker(picker, requestId: requestId)
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
        cancelImagePicker()
    }

    /// 优先读取系统提供的原始文件；拍照无 URL 时回退到 UIImage JPEG 数据。
    public func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        guard pickerController === picker, let request = pickerRequest else { return }
        let url = info[.imageURL] as? URL
        let image = info[.originalImage] as? UIImage
        DispatchQueue.global(qos: .userInitiated).async {
            let selected = autoreleasepool { () -> SelectedImage? in
                if let url, let data = try? Data(contentsOf: url),
                   let type = UTType(filenameExtension: url.pathExtension),
                   let selected = ImageSelectionProcessor.selectedImage(
                        data: data,
                        suggestedName: url.lastPathComponent,
                        typeIdentifier: type.identifier,
                        policy: request.compression
                   ) {
                    return selected
                }
                guard let data = image?.jpegData(compressionQuality: 1) else { return nil }
                return ImageSelectionProcessor.selectedImage(
                    data: data,
                    suggestedName: nil,
                    typeIdentifier: UTType.jpeg.identifier,
                    policy: request.compression
                )
            }
            UIKitExecutionContext.run {
                guard self.pickerRequest?.id == request.id, self.pickerController === picker else { return }
                if let selected {
                    self.completePicker([selected])
                } else {
                    self.finishPicker(error: "无法读取拍摄的图片")
                }
            }
        }
    }
}

extension MediaClient: PHPickerViewControllerDelegate {
    /// 并行读取多选图片，但按用户选择顺序组装最终结果。
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard pickerController === picker, let request = pickerRequest else { return }
        guard !results.isEmpty else {
            cancelImagePicker()
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        let policy = request.compression
        var loaded = Array<SelectedImage?>(repeating: nil, count: results.count)
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard let typeIdentifier = ImageSelectionProcessor.imageTypeIdentifier(for: provider) else { continue }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data else { return }
                let image = ImageSelectionProcessor.selectedImage(
                    data: data,
                    suggestedName: provider.suggestedName,
                    typeIdentifier: typeIdentifier,
                    policy: policy
                )
                lock.lock()
                loaded[index] = image
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self,
                  self.pickerRequest?.id == request.id,
                  self.pickerController === picker else { return }
            let images = loaded.compactMap { $0 }
            if images.isEmpty {
                finishPicker(error: "无法读取所选图片")
            } else {
                completePicker(images)
            }
        }
    }
}
