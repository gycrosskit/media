import Foundation
import UniformTypeIdentifiers

public enum MediaCapturePermission { case camera, microphone }

/// 原始文件入口；视频与普通文件保留 URL，不经过图片 bytes/Base64 通道。
public struct MediaFilePickerRequest {
    public let acceptTypes: [String]
    public let multiple: Bool
    public let capture: Bool
    public let maxFiles: Int
    public let maxBytes: Int
    public init(acceptTypes: [String], multiple: Bool, capture: Bool = false, maxFiles: Int = 10, maxBytes: Int = 50 * 1024 * 1024) {
        self.acceptTypes = acceptTypes; self.multiple = multiple; self.capture = capture
        self.maxFiles = maxFiles; self.maxBytes = maxBytes
    }
    var prefersCurrentRepresentation = false
    var maxTotalBytes: Int?
    var captureJPEGQuality = 0.9
    private var normalizedTypes: [String] {
        acceptTypes.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
    private func resolve(_ value: String) -> UTType {
        if value == "image" || value == "image/*" { return .image }
        if value == "video" || value == "video/*" { return .movie }
        if value == "image/jpg" { return .jpeg }
        if value == "video/mov" { return .quickTimeMovie }
        if value.isEmpty || value == "*/*" || value == "*" { return .item }
        if value.hasPrefix(".") { return UTType(filenameExtension: String(value.dropFirst())) ?? .item }
        if value.contains("/") { return UTType(mimeType: value) ?? .item }
        return UTType(value) ?? .item
    }
    /// UI 分类采用显式 MIME family；结果仍按下方具体 types 校验，未知 specific 不扩大授权格式。
    var selectionTypes: [UTType] {
        normalizedTypes.map { value in
            if value.hasPrefix("image/") { return .image }
            if value.hasPrefix("video/") { return .movie }
            return resolve(value)
        }
    }
    var types: [UTType] { normalizedTypes.isEmpty ? [.item] : normalizedTypes.map(resolve) }
    func accepts(_ type: UTType) -> Bool {
        if normalizedTypes.isEmpty { return type.conforms(to: .item) }
        return normalizedTypes.contains { value in
            if (value.hasPrefix("image/") || value.hasPrefix("video/")),
               value != "image/*", value != "video/*", value != "image/jpg", value != "video/mov",
               UTType(mimeType: value) == nil { return false }
            return type.conforms(to: resolve(value))
        }
    }
    var mediaOnly: Bool { !selectionTypes.isEmpty && selectionTypes.allSatisfy { $0.conforms(to: .image) || $0.conforms(to: .movie) } }
    var image: Bool { selectionTypes.contains { $0.conforms(to: .image) } }
    var video: Bool { selectionTypes.contains { $0.conforms(to: .movie) } }
    var captureImage: Bool { accepts(.jpeg) || accepts(.png) }
    var captureVideo: Bool { accepts(.quickTimeMovie) || accepts(.mpeg4Movie) }
    var captureTypes: [String] { (captureImage ? [UTType.image.identifier] : []) + (captureVideo ? [UTType.movie.identifier] : []) }
}

public struct MediaSelectedFile {
    public let url: URL
    public let fileName: String
    public let contentType: String
    public let size: Int
}

public enum MediaFilePickerResult {
    /// token 属于 media；宿主在文件不再被网页读取时调用 releaseFiles(token:)。
    case selected(token: UUID, files: [MediaSelectedFile])
    case cancelled
    case permissionDenied(MediaCapturePermission)
    case permissionBlocked(MediaCapturePermission)
    case permissionRestricted(MediaCapturePermission)
    case failed(String)
}
