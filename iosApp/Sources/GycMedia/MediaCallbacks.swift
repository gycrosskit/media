import Foundation
/// 一次 Picker 的有序结果；所有回调在 Main，图片事件之后发送唯一终态。
public protocol MediaPickerCallback: AnyObject {
    /// 已读取的编码与建议文件名/MIME；无压缩请求时保留原始编码。
    func onImage(data: Data, fileName: String, contentType: String)
    /// 所有图片已交付，结束本次等待。
    func onCompleted()
    /// 用户取消 Picker，结束本次等待。
    func onCancelled()
    /// 本次首次拒绝系统权限。
    func onPermissionDenied()
    /// 此前已拒绝权限，需宿主引导设置恢复。
    func onPermissionBlocked()
    /// 设备策略限制，设置页无法恢复。
    func onPermissionRestricted()
    /// 读取或写入失败；message 供宿主本地化，不包含图片内容。
    func onFailed(message: String)
}
/// 相册写入唯一终态；Main 回调不代表被取消的等待能撤销已开始的写入。
public protocol MediaSaveCallback: AnyObject {
    /// Photos 已完成保存。
    func onSaved()
    /// 本次首次拒绝系统权限。
    func onPermissionDenied()
    /// 此前已拒绝权限，需宿主引导设置恢复。
    func onPermissionBlocked()
    /// 设备策略限制，设置页无法恢复。
    func onPermissionRestricted()
    /// 图片不可解码，未请求保存。
    func onInvalidContent()
    /// 读取或写入失败；message 供宿主本地化，不包含图片内容。
    func onFailed(message: String)
}
