import Foundation
public protocol MediaPickerCallback: AnyObject {
    func onImage(data: Data, fileName: String, contentType: String)
    func onCompleted()
    func onCancelled()
    func onPermissionDenied()
    func onPermissionBlocked()
    func onPermissionRestricted()
    func onFailed(message: String)
}
public protocol MediaSaveCallback: AnyObject {
    func onSaved()
    func onPermissionDenied()
    func onPermissionBlocked()
    func onPermissionRestricted()
    func onInvalidContent()
    func onFailed(message: String)
}
