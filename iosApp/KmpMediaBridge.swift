// 将此薄适配文件加入宿主 iOS target；若 KMP 框架名为 Shared，只改下面的 import。
import MediaCore
import GycMedia
import Foundation

final class KmpMediaBridge: IosMediaSdkBridge {
    func pickImages(source: Int32, maxCount: Int32, maxDimension: Int32, jpegQuality: Int32, callback: IosImagePickerSdkCallback) {
        MediaClient.shared.pickImages(source: source, maxCount: maxCount, maxDimension: maxDimension,
            jpegQuality: jpegQuality, callback: PickerCallback(callback))
    }
    func cancelImagePicker() { MediaClient.shared.cancelImagePicker() }
    func saveImage(data: Data, fileNamePrefix: String, callback: IosImageSaveSdkCallback) {
        MediaClient.shared.saveImage(data: data, fileNamePrefix: fileNamePrefix, callback: SaveCallback(callback))
    }
}
private final class PickerCallback: MediaPickerCallback {
    let delegate: IosImagePickerSdkCallback
    init(_ delegate: IosImagePickerSdkCallback) { self.delegate = delegate }
    func onImage(data: Data, fileName: String, contentType: String) { delegate.onImage(data: data, fileName: fileName, contentType: contentType) }
    func onCompleted() { delegate.onCompleted() }
    func onCancelled() { delegate.onCancelled() }
    func onPermissionDenied() { delegate.onPermissionDenied() }
    func onPermissionBlocked() { delegate.onPermissionBlocked() }
    func onPermissionRestricted() { delegate.onPermissionRestricted() }
    func onFailed(message: String) { delegate.onFailed(message: message) }
}
private final class SaveCallback: MediaSaveCallback {
    let delegate: IosImageSaveSdkCallback
    init(_ delegate: IosImageSaveSdkCallback) { self.delegate = delegate }
    func onSaved() { delegate.onSaved() }
    func onPermissionDenied() { delegate.onPermissionDenied() }
    func onPermissionBlocked() { delegate.onPermissionBlocked() }
    func onPermissionRestricted() { delegate.onPermissionRestricted() }
    func onInvalidContent() { delegate.onInvalidContent() }
    func onFailed(message: String) { delegate.onFailed(message: message) }
}
