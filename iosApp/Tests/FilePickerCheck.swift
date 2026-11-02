import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ObjectiveC.runtime
@testable import GycMedia

private final class FilePresenter: UIViewController {
    var last: UIViewController?
    var actuallyPresent = true
    var appeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false }
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        last = controller
        controller.modalPresentationStyle = .fullScreen
        if actuallyPresent { super.present(controller, animated: false, completion: completion) } else { completion?() }
    }
}
private final class CameraSystem: NSObject {
    static var camera = AVAuthorizationStatus.authorized
    static var microphone = AVAuthorizationStatus.authorized
    @objc class func available(_ source: Int) -> Bool { true }
    @objc class func types(_ source: Int) -> [String] { [UTType.image.identifier, UTType.movie.identifier] }
    @objc class func authorized(_ media: NSString) -> Int { (media as String == AVMediaType.audio.rawValue ? microphone : camera).rawValue }
    @objc class func deny(_ media: NSString, completion: @escaping (Bool) -> Void) { if media as String == AVMediaType.audio.rawValue { microphone = .denied } else { camera = .denied }; completion(false) }
    @objc func cameraSource(_ source: Int) {} // Simulator 无 camera，只替换硬件入口。
}
private final class ReplacedImageCallback: MediaPickerCallback {
    var cancelled = 0
    func onImage(data: Data, fileName: String, contentType: String) { preconditionFailure("Unexpected image") }
    func onCompleted() { preconditionFailure("Unexpected image completion") }
    func onCancelled() { cancelled += 1 }
    func onPermissionDenied() { preconditionFailure("Unexpected image permission") }
    func onPermissionBlocked() { preconditionFailure("Unexpected image permission") }
    func onPermissionRestricted() { preconditionFailure("Unexpected image permission") }
    func onFailed(message: String) { preconditionFailure("Unexpected image failure") }
}
private final class LegacyImageOutput: MediaPickerCallback {
    var images: [Data] = []
    var mimes: [String] = []
    var completed = 0
    var cancelled = 0
    var failed = 0
    var failures: [String] = []
    var names: [String] = []
    func onImage(data: Data, fileName: String, contentType: String) { images.append(data); mimes.append(contentType); names.append(fileName) }
    func onCompleted() { completed += 1 }
    func onCancelled() { cancelled += 1 }
    func onPermissionDenied() { preconditionFailure("Unexpected legacy permission denial") }
    func onPermissionBlocked() { preconditionFailure("Unexpected legacy permission blockage") }
    func onPermissionRestricted() { preconditionFailure("Unexpected legacy permission restriction") }
    func onFailed(message: String) { failed += 1; failures.append(message) }
}
private final class SlowFileProvider: NSItemProvider {
    var reply: ((URL?, Error?) -> Void)?
    override var registeredTypeIdentifiers: [String] { [UTType.png.identifier] }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping (URL?, Error?) -> Void) -> Progress { reply = completionHandler; return Progress(totalUnitCount: 1) }
}
private func provider(_ url: URL, type: UTType) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in completion(url, false, nil); return nil }
    return provider
}
@MainActor private func awaitFile(_ message: String, _ condition: () -> Bool) async {
    for _ in 0..<300 { if condition() { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
    preconditionFailure(message)
}

@MainActor func checkFilePicker(window: UIWindow) async {
    precondition(MediaFilePickerRequest(acceptTypes: ["image/future-format"], multiple: false).mediaOnly)
    precondition(!MediaFilePickerRequest(acceptTypes: ["image/future-format"], multiple: false).accepts(.jpeg))
    precondition(!MediaFilePickerRequest(acceptTypes: ["video/future-format"], multiple: false).accepts(.mpeg4Movie))
    precondition(MediaFilePickerRequest(acceptTypes: ["video/mov"], multiple: false).accepts(.quickTimeMovie))
    let client = MediaClient.shared
    let root = FilePresenter(); window.rootViewController = root; window.makeKeyAndVisible()
    await awaitFile("File presenter did not appear") { root.appeared }
    root.actuallyPresent = false
    client.presenterResolver = { root }
    let legacy = ReplacedImageCallback(); var rawCancelled = 0
    client.pickImages(source: 1, maxCount: 1, maxDimension: 0, jpegQuality: 0, callback: legacy)
    let rawId = client.pickFiles(MediaFilePickerRequest(acceptTypes: ["image/*"], multiple: false), presenter: root) { state in if case .cancelled = state { rawCancelled += 1 } else { preconditionFailure("Unexpected replacement result") } }
    precondition(legacy.cancelled == 1)
    client.cancelImagePicker()
    precondition(rawCancelled == 0, "Late image Renderer disposal cancelled a new raw-file request")
    client.cancelFiles(requestId: rawId); precondition(rawCancelled == 1)
    for accepts in [["image/*"], [".png"], ["video/mp4"], ["image/*", "video/*"], ["application/pdf"], [], ["*/*"], ["image/*", "application/pdf"]] {
        var cancelled = 0
        let id = client.pickFiles(MediaFilePickerRequest(acceptTypes: accepts, multiple: true), presenter: root) { state in if case .cancelled = state { cancelled += 1 } else { preconditionFailure("Unexpected selection") } }
        if accepts == ["image/*"] || accepts == [".png"] || accepts == ["video/mp4"] || accepts == ["image/*", "video/*"] {
            let picker = root.last as! PHPickerViewController
            precondition(picker.configuration.selectionLimit == 10)
            let expected: PHPickerFilter = accepts == ["image/*", "video/*"] ? .any(of: [.images, .videos]) : accepts == ["video/mp4"] ? .videos : .images
            precondition(picker.configuration.filter == expected)
        } else { precondition(root.last is UIDocumentPickerViewController) }
        client.cancelFiles(requestId: id); precondition(cancelled == 1)
    }
    root.actuallyPresent = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    let bitmap = renderer.image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("native-provider.png")
    try! bitmap.pngData()!.write(to: source)
    let encodedTarget = FileManager.default.temporaryDirectory.appendingPathComponent("capture-encode-check.png")
    do { _ = try MediaClient.writeCapturedImage(UIImage(), options: MediaFilePickerRequest(acceptTypes: ["image/png"], multiple: false), to: encodedTarget); preconditionFailure("Empty UIImage encoded unexpectedly") }
    catch CaptureImageFileError.encoding {} catch { preconditionFailure("Encoding failure lost its phase") }
    do { _ = try MediaClient.writeCapturedImage(bitmap, options: MediaFilePickerRequest(acceptTypes: ["image/png"], multiple: false, maxBytes: 1), to: encodedTarget); preconditionFailure("Over-budget capture encoded unexpectedly") }
    catch ImageSelectionError.tooLarge {} catch { preconditionFailure("Capture limit lost its classification") }
    let unavailableTarget = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("image.png")
    do { _ = try MediaClient.writeCapturedImage(bitmap, options: MediaFilePickerRequest(acceptTypes: ["image/png"], multiple: false), to: unavailableTarget); preconditionFailure("Missing directory accepted capture write") }
    catch CaptureImageFileError.writing {} catch { preconditionFailure("Write failure was reported as encoding or size failure") }
    precondition(!FileManager.default.fileExists(atPath: encodedTarget.path) && !FileManager.default.fileExists(atPath: unavailableTarget.path))
    defer { try? FileManager.default.removeItem(at: source); client.presenterResolver = nil }
    let movie = Bundle.main.url(forResource: "capture", withExtension: "mov")!
    for compressed in [false, true] {
        let output = LegacyImageOutput()
        client.pickImages(source: 1, maxCount: 500, maxDimension: compressed ? 2 : 0, jpegQuality: compressed ? 85 : 0, callback: output)
        await awaitFile("Legacy image adapter did not use shared raw picker") { root.last is PHPickerViewController && root.last?.presentingViewController != nil && root.last?.isBeingPresented == false }
        let picker = root.last as! PHPickerViewController
        precondition(picker.configuration.selectionLimit == 500 && picker.configuration.preferredAssetRepresentationMode == .current, "Legacy count/current representation changed")
        client.finishPhotoFileSelection(picker, providers: [provider(source, type: .png)])
        await awaitFile("Legacy raw lease was not converted to bytes") { output.completed == 1 }
        precondition(output.images.count == 1 && output.failed == 0 && output.cancelled == 0)
        if compressed { precondition(output.mimes == ["image/jpeg"] && output.images[0].prefix(2) == Data([255, 216])) }
        else { precondition(output.mimes == ["image/png"] && output.images[0] == (try! Data(contentsOf: source))) }
    }
    let overA = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-budget-a.png")
    let overB = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-budget-b.png")
    for url in [overA, overB] { FileManager.default.createFile(atPath: url.path, contents: nil); let file = try! FileHandle(forWritingTo: url); try! file.truncate(atOffset: 17 * 1024 * 1024); try! file.close() }
    let over = LegacyImageOutput()
    client.pickImages(source: 1, maxCount: 500, maxDimension: 0, jpegQuality: 0, callback: over)
    await awaitFile("Legacy budget picker did not present") { root.last is PHPickerViewController && root.last?.presentingViewController != nil && root.last?.isBeingPresented == false }
    client.finishPhotoFileSelection(root.last as! PHPickerViewController, providers: [provider(overA, type: .png), provider(overB, type: .png)])
    await awaitFile("Legacy 32MiB aggregate source budget was not enforced") { over.failed == 1 }
    precondition(over.images.isEmpty && over.completed == 0)
    for url in [overA, overB] { try? FileManager.default.removeItem(at: url) }
    let cancelledBytes = LegacyImageOutput()
    client.pickImages(source: 1, maxCount: 1, maxDimension: 0, jpegQuality: 0, callback: cancelledBytes)
    await awaitFile("Legacy adapter cancellation picker did not present") { root.last is PHPickerViewController && root.last?.presentingViewController != nil && root.last?.isBeingPresented == false }
    client.finishPhotoFileSelection(root.last as! PHPickerViewController, providers: [provider(source, type: .png)])
    client.cancelImagePicker()
    await awaitFile("Legacy adapter did not cancel shared request") { cancelledBytes.cancelled == 1 }
    await awaitFile("Cancelled legacy picker did not finish dismissal") { root.appeared && root.presentedViewController == nil }
    precondition(cancelledBytes.images.isEmpty && cancelledBytes.completed == 0)
    var selected: (UUID, [MediaSelectedFile])?
    client.pickFiles(MediaFilePickerRequest(acceptTypes: ["image/*", "video/*"], multiple: true), presenter: root) { state in
        guard case .selected(let token, let files) = state else { preconditionFailure("Mixed selection failed") }
        precondition(root.appeared && root.presentedViewController == nil, "File callback preceded dismiss/host appearance")
        selected = (token, files)
    }
    await awaitFile("Library picker did not hide host") { root.last is PHPickerViewController && !root.appeared && root.last?.isBeingPresented == false }
    client.finishPhotoFileSelection(root.last as! PHPickerViewController, providers: [provider(source, type: .png), provider(movie, type: .quickTimeMovie)])
    await awaitFile("Real providers did not return PNG/video file URLs") { selected != nil }
    precondition(selected!.1.count == 2 && selected!.1.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) && $0.size > 0 && !$0.contentType.isEmpty })
    let accepted = selected!
    client.cancelFiles(requestId: accepted.0)
    precondition(accepted.1.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "Cancel deleted already delivered files")
    client.releaseFiles(token: accepted.0); client.releaseFiles(token: accepted.0)
    precondition(accepted.1.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    precondition(FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: movie.path))
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("LICENSE")
    let custom = FileManager.default.temporaryDirectory.appendingPathComponent("custom.fixtureunknown")
    try! Data("plain".utf8).write(to: plain); try! Data("custom".utf8).write(to: custom)
    selected = nil
    client.pickFiles(MediaFilePickerRequest(acceptTypes: [], multiple: true), presenter: root) { state in
        guard case .selected(let token, let files) = state else { preconditionFailure("Generic raw file selection failed") }
        selected = (token, files)
    }
    await awaitFile("Document picker did not present") { root.last is UIDocumentPickerViewController && root.last?.isBeingPresented == false && root.last?.presentingViewController != nil }
    client.documentPicker(root.last as! UIDocumentPickerViewController, didPickDocumentsAt: [plain, custom])
    await awaitFile("Unknown and extensionless files did not return") { selected != nil }
    precondition(selected!.1.map(\.fileName) == ["LICENSE", "custom.fixtureunknown"] && selected!.1[0].url.pathExtension.isEmpty && selected!.1[1].url.pathExtension == "fixtureunknown")
    client.releaseFiles(token: selected!.0)
    try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: custom)

    let available = class_getClassMethod(UIImagePickerController.self, #selector(UIImagePickerController.isSourceTypeAvailable(_:)))!
    let types = class_getClassMethod(UIImagePickerController.self, #selector(UIImagePickerController.availableMediaTypes(for:)))!
    let oldTypes = method_setImplementation(types, method_getImplementation(class_getClassMethod(CameraSystem.self, #selector(CameraSystem.types(_:)))!))
    let authorized = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.authorizationStatus(for:)))!
    let setSource = class_getInstanceMethod(UIImagePickerController.self, #selector(setter: UIImagePickerController.sourceType))!
    let oldAvailable = method_setImplementation(available, method_getImplementation(class_getClassMethod(CameraSystem.self, #selector(CameraSystem.available(_:)))!))
    let oldAuthorized = method_setImplementation(authorized, method_getImplementation(class_getClassMethod(CameraSystem.self, #selector(CameraSystem.authorized(_:)))!))
    let oldSource = method_setImplementation(setSource, method_getImplementation(class_getInstanceMethod(CameraSystem.self, #selector(CameraSystem.cameraSource(_:)))!))
    let access = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.requestAccess(for:completionHandler:)))!
    let oldAccess = method_setImplementation(access, method_getImplementation(class_getClassMethod(CameraSystem.self, #selector(CameraSystem.deny(_:completion:)))!))
    defer { method_setImplementation(access, oldAccess); method_setImplementation(types, oldTypes); method_setImplementation(available, oldAvailable); method_setImplementation(authorized, oldAuthorized); method_setImplementation(setSource, oldSource) }
    for accept in ["image/png", "video/quicktime", "video/mp4"] {
        CameraSystem.microphone = accept == "image/png" ? .denied : .authorized
        selected = nil
        let request = client.pickFiles(MediaFilePickerRequest(acceptTypes: [accept], multiple: false, capture: true), presenter: root) { state in
            guard case .selected(let token, let files) = state else { preconditionFailure("Capture failed") }
            precondition(root.appeared && root.presentedViewController == nil, "Use Photo returned before full-screen dismissal")
            selected = (token, files)
        }
        await awaitFile("Full-screen capture did not hide host") { root.last is UIImagePickerController && !root.appeared && root.last?.isBeingPresented == false }
        let picker = root.last as! UIImagePickerController
        let info: [UIImagePickerController.InfoKey: Any] = accept == "image/png" ? [.mediaType: UTType.image.identifier, .originalImage: bitmap] : [.mediaType: UTType.movie.identifier, .mediaURL: movie]
        let before = Set((try! FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "mov" })
        client.imagePickerController(picker, didFinishPickingMediaWithInfo: info)
        let snapshots = Set((try! FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "mov" }).subtracting(before)
        if accept != "image/png" { precondition(snapshots.count == 1, "Movie must be preserved once before dismiss") }
        await awaitFile("Completed camera did not dismiss before file processing") { root.appeared && root.presentedViewController == nil }
        await awaitFile("Capture output did not complete") { selected != nil }
        let file = selected!.1[0]
        precondition(file.contentType == accept && file.size > 0)
        if accept == "video/quicktime" { precondition(snapshots.contains(file.url), "Owned capture was copied again after dismiss") }
        if accept == "video/mp4" { precondition(snapshots.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Converted MOV snapshot was not cleaned up") }
        if accept == "image/png" { precondition((try! Data(contentsOf: file.url)).prefix(4) == Data([137, 80, 78, 71])) }
        else { precondition(!AVURLAsset(url: file.url).tracks(withMediaType: .video).isEmpty) }
        client.cancelFiles(requestId: request); precondition(FileManager.default.fileExists(atPath: file.url.path))
        client.releaseFiles(token: selected!.0); precondition(!FileManager.default.fileExists(atPath: file.url.path))
    }
    let originalCapture = LegacyImageOutput()
    client.pickImages(source: 0, maxCount: 1, maxDimension: 0, jpegQuality: 0, callback: originalCapture)
    await awaitFile("Legacy camera did not present") { root.last is UIImagePickerController && !root.appeared && root.last?.isBeingPresented == false }
    client.imagePickerController(root.last as! UIImagePickerController, didFinishPickingMediaWithInfo: [.mediaType: UTType.image.identifier, .imageURL: source, .originalImage: bitmap])
    await awaitFile("Retained legacy camera URL did not produce bytes") { originalCapture.completed == 1 }
    precondition(originalCapture.images == [try! Data(contentsOf: source)] && originalCapture.names == [source.lastPathComponent], "Original snapshot bytes/name were not retained")
    let captureOver = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-capture-over.png")
    FileManager.default.createFile(atPath: captureOver.path, contents: nil)
    let overHandle = try! FileHandle(forWritingTo: captureOver); try! overHandle.truncate(atOffset: UInt64(MediaClient.maxBytes + 1)); try! overHandle.close()
    let captureLimit = LegacyImageOutput()
    client.pickImages(source: 0, maxCount: 1, maxDimension: 0, jpegQuality: 0, callback: captureLimit)
    await awaitFile("Legacy capture limit picker did not present") { root.last is UIImagePickerController && !root.appeared && root.last?.isBeingPresented == false }
    client.imagePickerController(root.last as! UIImagePickerController, didFinishPickingMediaWithInfo: [.mediaType: UTType.image.identifier, .imageURL: captureOver, .originalImage: bitmap])
    await awaitFile("Legacy oversized capture did not fail") { captureLimit.failed == 1 }
    precondition(captureLimit.failures == [MediaClient.limitExceededMessage] && captureLimit.images.isEmpty)
    try? FileManager.default.removeItem(at: captureOver)
    for invalidate in [false, true] {
        var terminal: MediaFilePickerResult?
        let id = client.pickFiles(MediaFilePickerRequest(acceptTypes: ["video/quicktime"], multiple: false, capture: true), presenter: root) { terminal = $0 }
        await awaitFile("Retained movie cancellation picker did not present") { root.last is UIImagePickerController && !root.appeared && root.last?.isBeingPresented == false }
        let picker = root.last as! UIImagePickerController
        let before = Set((try! FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "mov" })
        client.imagePickerController(picker, didFinishPickingMediaWithInfo: [.mediaType: UTType.movie.identifier, .mediaURL: movie])
        let retained = Set((try! FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "mov" }).subtracting(before)
        precondition(retained.count == 1)
        if invalidate {
            let file = try! FileHandle(forWritingTo: retained.first!); try! file.truncate(atOffset: 50 * 1024 * 1024 + 1); try! file.close()
        } else { client.cancelFiles(requestId: id) }
        await awaitFile("Retained movie request did not settle") { terminal != nil }
        if invalidate { guard case .failed("File exceeds selection size limit") = terminal! else { preconditionFailure("Post-dismiss capture size was not revalidated") } }
        else { guard case .cancelled = terminal! else { preconditionFailure("Cancelled retained capture returned a file") } }
        await awaitFile("Retained movie dismissal did not finish") { root.appeared && root.presentedViewController == nil }
        precondition(retained.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Cancelled or invalid snapshot leaked")
        client.imagePickerController(picker, didFinishPickingMediaWithInfo: [.mediaType: UTType.movie.identifier, .mediaURL: movie])
        precondition(retained.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    let invalidMovie = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-camera.mp4")
    try! Data("not a video".utf8).write(to: invalidMovie)
    var invalidMovieResult: MediaFilePickerResult?
    client.pickFiles(MediaFilePickerRequest(acceptTypes: ["video/mp4"], multiple: false, capture: true), presenter: root) { invalidMovieResult = $0 }
    await awaitFile("Invalid movie picker did not present") { root.last is UIImagePickerController && !root.appeared && root.last?.isBeingPresented == false }
    client.imagePickerController(root.last as! UIImagePickerController, didFinishPickingMediaWithInfo: [.mediaType: UTType.movie.identifier, .mediaURL: invalidMovie])
    await awaitFile("MP4-only capture skipped AVFoundation validation") { invalidMovieResult != nil }
    guard case .failed = invalidMovieResult! else { preconditionFailure("A non-video .mp4 was accepted from capture") }
    precondition(FileManager.default.fileExists(atPath: invalidMovie.path), "Invalid capture deleted provider-owned source")
    try? FileManager.default.removeItem(at: invalidMovie)
    for video in [false, true] {
        CameraSystem.camera = video ? .authorized : .notDetermined
        CameraSystem.microphone = video ? .notDetermined : .denied
        for blocked in [false, true] {
            var settled = false
            client.pickFiles(MediaFilePickerRequest(acceptTypes: [video ? "video/mp4" : "image/png"], multiple: false, capture: true), presenter: root) { state in
                let permission: MediaCapturePermission
                switch state {
                case .permissionDenied(let value): precondition(!blocked); permission = value
                case .permissionBlocked(let value): precondition(blocked); permission = value
                default: preconditionFailure("Native first denial was not distinguished from known blockage")
                }
                precondition(permission == (video ? .microphone : .camera)); settled = true
            }
            await awaitFile("Native denial did not terminate") { settled }
        }
    }
    CameraSystem.camera = .authorized; CameraSystem.microphone = .authorized
    var oldCancelled = 0, newCancelled = 0
    let oldId = client.pickFiles(MediaFilePickerRequest(acceptTypes: ["image/*"], multiple: true), presenter: root) { state in if case .cancelled = state { oldCancelled += 1 } else { preconditionFailure("Old request delivered after cancel") } }
    await awaitFile("Old library did not present") { root.last is PHPickerViewController && root.last?.isBeingPresented == false && root.last?.presentingViewController != nil }
    let delayed = SlowFileProvider()
    client.finishPhotoFileSelection(root.last as! PHPickerViewController, providers: [provider(source, type: .png), delayed])
    await awaitFile("Partial import did not reach second provider") { delayed.reply != nil }
    client.cancelFiles(requestId: oldId)
    precondition(oldCancelled == 1)
    let newId = client.pickFiles(MediaFilePickerRequest(acceptTypes: ["image/*"], multiple: false), presenter: root) { state in if case .cancelled = state { newCancelled += 1 } else { preconditionFailure("Old URL reached new selection") } }
    delayed.reply?(source, nil); delayed.reply = nil
    try? await Task.sleep(nanoseconds: 50_000_000)
    precondition(newCancelled == 0)
    client.cancelFiles(requestId: oldId); precondition(newCancelled == 0)
    client.cancelFiles(requestId: newId)
    await awaitFile("New selection did not cancel") { newCancelled == 1 }
    print("PASS: File picker reuse: system image/video/mixed/document routing, real providers, raw URL metadata, full-screen Use Photo/MP4, dismissal-before-result, token release, cancellation and stale request isolation (camera authorization/hardware fixtures)")
}
