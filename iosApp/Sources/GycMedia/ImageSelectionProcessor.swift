import UIKit
import UniformTypeIdentifiers

/** 单次图片选择的压缩边界。 */
struct ImageSelectionPolicy {
    /// 最长边的像素上限；不能直接按 UIKit point 比较，否则 Retina 图片会超出上传限制。
    let maxDimension: CGFloat
    /// JPEG 编码质量，范围 0...1；由 shared 的百分比参数转换而来。
    let quality: CGFloat
    /// 单张 JPEG 编码预算，默认与 shared 相同；与原始编码的总量检查分开。
    var maxEncodedBytes: Int = MediaClient.maxBytes
}

enum ImageSelectionError: Error { case tooLarge }

/** Swift 内部图片快照；三个字段共同组成 shared 上传边界的一项结果。 */
struct SelectedImage {
    let data: Data
    let fileName: String
    let contentType: String
}

/** 图片编码、文件名和 UTType 处理不依赖 Picker 生命周期。 */
enum ImageSelectionProcessor {
    /// 压缩结果统一为 JPEG，并同步扩展名和 MIME；无压缩策略时保留来源编码。
    static func selectedImage(
        data: Data,
        suggestedName: String?,
        typeIdentifier: String,
        policy: ImageSelectionPolicy?
    ) throws -> SelectedImage? {
        guard !data.isEmpty else { return nil }
        guard data.count <= MediaClient.maxBytes else { throw ImageSelectionError.tooLarge }
        if let policy {
            guard let image = UIImage(data: data),
                  let compressed = compress(image: image, policy: policy) else {
                return nil
            }
            guard compressed.count <= min(policy.maxEncodedBytes, MediaClient.maxBytes) else {
                throw ImageSelectionError.tooLarge
            }
            return SelectedImage(
                data: compressed,
                fileName: jpegFileName(suggestedName),
                contentType: UTType.jpeg.preferredMIMEType ?? "image/jpeg"
            )
        }
        let type = UTType(typeIdentifier)
        return SelectedImage(
            data: data,
            fileName: fileName(
                suggestedName,
                fallbackExtension: type?.preferredFilenameExtension ?? "img"
            ),
            contentType: type?.preferredMIMEType ?? "application/octet-stream"
        )
    }

    static func compress(image: UIImage, policy: ImageSelectionPolicy) -> Data? {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(size.width, size.height)
        let scale = longest > policy.maxDimension ? policy.maxDimension / longest : 1
        let targetSize = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
        let output: UIImage
        if scale < 1 || image.scale != 1 {
            let format = UIGraphicsImageRendererFormat()
            // targetSize 已经是像素值，不能再叠加设备屏幕倍率。
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            output = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            output = image
        }
        return output.jpegData(compressionQuality: policy.quality)
    }

    static func jpegFileName(_ suggestedName: String?) -> String {
        let name = (suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let component = (name as NSString).lastPathComponent
        let stem = (component as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = stem.isEmpty || stem == "." || stem == ".."
            ? "ios_\(UUID().uuidString.lowercased())"
            : stem
        return "\(safeStem).jpg"
    }

    static func fileName(_ suggestedName: String?, fallbackExtension: String) -> String {
        let value = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            return (value as NSString).pathExtension.isEmpty
                ? "\(value).\(fallbackExtension)"
                : value
        }
        return "ios_\(UUID().uuidString.lowercased()).\(fallbackExtension)"
    }

    static func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
    }
}
