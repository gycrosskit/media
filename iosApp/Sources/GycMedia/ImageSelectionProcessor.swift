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

    /// Main owns the sequence; provider temporary files are read before its callback returns.
    /// One file is in flight, and cancellation/owner replacement prevents starting a successor.
    static func readImages(
        _ providers: [NSItemProvider], policy: ImageSelectionPolicy?,
        isActive: @escaping () -> Bool,
        completion: @escaping (Result<[SelectedImage], ImageSelectionError>) -> Void
    ) -> Progress {
        precondition(Thread.isMainThread)
        let progress = Progress(totalUnitCount: Int64(providers.count))
        var images: [SelectedImage] = []
        var originalBytes = 0
        var outputBytes = 0
        func loadNext(_ index: Int) {
            guard !progress.isCancelled, isActive() else { return }
            guard index < providers.count else {
                // Completion can reenter the picker; never run it before its Progress is returned.
                DispatchQueue.main.async {
                    if !progress.isCancelled && isActive() { completion(.success(images)) }
                }
                return
            }
            let provider = providers[index]
            guard let type = imageTypeIdentifier(for: provider) else { loadNext(index + 1); return }
            let remaining = MediaClient.maxBytes - originalBytes
            let child = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard !progress.isCancelled else { return }
                let active = Thread.isMainThread ? isActive() : DispatchQueue.main.sync(execute: isActive)
                guard active else { return }
                var selected: SelectedImage?
                var readBytes = 0
                var tooLarge = false
                do {
                    if let url {
                        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > remaining {
                            throw ImageSelectionError.tooLarge
                        }
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        var data = Data()
                        // A changed/unknown file length must still stop at one byte beyond the budget.
                        while let chunk = try file.read(upToCount: min(64 * 1024, remaining + 1 - data.count)), !chunk.isEmpty {
                            guard !progress.isCancelled else { return }
                            data.append(chunk)
                            if data.count > remaining { throw ImageSelectionError.tooLarge }
                        }
                        readBytes = data.count
                        selected = try selectedImage(data: data, suggestedName: provider.suggestedName,
                                                     typeIdentifier: type, policy: policy)
                    }
                } catch ImageSelectionError.tooLarge { tooLarge = true }
                  catch { /* An unreadable provider does not discard other selected images. */ }
                DispatchQueue.main.async {
                    guard !progress.isCancelled, isActive() else { return }
                    originalBytes += readBytes
                    outputBytes += selected?.data.count ?? 0
                    guard !tooLarge, outputBytes <= MediaClient.maxBytes else {
                        completion(.failure(.tooLarge)); return
                    }
                    if let selected { images.append(selected) }
                    loadNext(index + 1)
                }
            }
            progress.addChild(child, withPendingUnitCount: 1)
        }
        loadNext(0)
        return progress
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
        let component = fileName(suggestedName, fallbackExtension: "jpg")
        let stem = (component as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = stem.isEmpty || stem == "." || stem == ".."
            ? "ios_\(UUID().uuidString.lowercased())"
            : stem
        return "\(safeStem).jpg"
    }

    static func fileName(_ suggestedName: String?, fallbackExtension: String) -> String {
        let name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value != "." && value != ".." && value != "/" {
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
