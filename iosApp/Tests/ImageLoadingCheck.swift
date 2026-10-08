import Foundation
import UIKit
@testable import GycMedia

private final class FileProvider: NSItemProvider {
    var starts = 0
    let transfer = Progress(totalUnitCount: 1)
    var response: ((URL?, Error?) -> Void)?
    var types = ["public.png"]
    override var registeredTypeIdentifiers: [String] { types }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping (URL?, Error?) -> Void) -> Progress {
        starts += 1
        response = completionHandler
        return transfer
    }
}

@MainActor private func waitForImageCheck(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure("Image loading fixture did not settle")
}

@MainActor func checkImageLoading() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let one = directory.appendingPathComponent("one.png"), two = directory.appendingPathComponent("two.png")
    try! Data([1, 2]).write(to: one); try! Data([3]).write(to: two)
    let first = FileProvider(), second = FileProvider()
    first.suggestedName = "../private/one.png"; second.suggestedName = "two.png"
    var result: Result<[SelectedImage], ImageSelectionError>?
    _ = ImageSelectionProcessor.readImages([first, second], policy: nil, isActive: { true }) { result = $0 }
    precondition(first.starts == 1 && second.starts == 0)
    first.response?(one, nil)
    await waitForImageCheck { second.starts == 1 }
    precondition(result == nil)
    second.response?(two, nil)
    await waitForImageCheck { result != nil }
    let images = try! result!.get()
    precondition(images.map(\.data) == [Data([1, 2]), Data([3])])
    precondition(images.map(\.fileName) == ["one.png", "two.png"])

    // Sparse file rejects before reading its contents and never starts another provider.
    let huge = directory.appendingPathComponent("huge.png")
    FileManager.default.createFile(atPath: huge.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: huge)
    try! handle.truncate(atOffset: UInt64(MediaClient.maxBytes + 1)); try! handle.close()
    let over = FileProvider(), afterOver = FileProvider(); result = nil
    _ = ImageSelectionProcessor.readImages([over, afterOver], policy: nil, isActive: { true }) { result = $0 }
    over.response?(huge, nil)
    await waitForImageCheck { result != nil }
    guard case .failure(.tooLarge) = result! else { preconditionFailure("Expected source budget failure") }
    precondition(afterOver.starts == 0)

    // Each file fits alone; the second must fail against the remaining batch budget.
    let fullURL = directory.appendingPathComponent("full.png")
    FileManager.default.createFile(atPath: fullURL.path, contents: nil)
    let fullHandle = try! FileHandle(forWritingTo: fullURL)
    try! fullHandle.truncate(atOffset: UInt64(MediaClient.maxBytes)); try! fullHandle.close()
    let full = FileProvider(), extra = FileProvider(), afterExtra = FileProvider(); result = nil
    _ = ImageSelectionProcessor.readImages([full, extra, afterExtra], policy: nil, isActive: { true }) { result = $0 }
    full.response?(fullURL, nil)
    await waitForImageCheck { extra.starts == 1 }
    precondition(result == nil)
    extra.response?(two, nil)
    await waitForImageCheck { result != nil }
    guard case .failure(.tooLarge) = result! else { preconditionFailure("Expected cumulative source budget failure") }
    precondition(afterExtra.starts == 0)

    let pending = FileProvider(), afterCancel = FileProvider(); var active = true; result = nil
    let progress = ImageSelectionProcessor.readImages([pending, afterCancel], policy: nil, isActive: { active }) { result = $0 }
    active = false; progress.cancel(); pending.response?(one, nil)
    try? await Task.sleep(nanoseconds: 10_000_000)
    precondition(pending.transfer.isCancelled && afterCancel.starts == 0 && result == nil)
    let old = FileProvider(), afterOld = FileProvider(); active = true
    _ = ImageSelectionProcessor.readImages([old, afterOld], policy: nil, isActive: { active }) { result = $0 }
    active = false; old.response?(one, nil)
    try? await Task.sleep(nanoseconds: 10_000_000)
    precondition(afterOld.starts == 0 && result == nil, "replaced owner cannot deliver or read a successor")

    let unsupported = FileProvider(); unsupported.types = []
    let replacement = FileProvider(); var returned = false; var ownerProgress: Progress?
    ownerProgress = ImageSelectionProcessor.readImages([unsupported], policy: nil, isActive: { true }) { value in
        precondition(returned, "synchronous completion would overwrite a reentrant owner")
        precondition((try! value.get()).isEmpty)
        ownerProgress = ImageSelectionProcessor.readImages([replacement], policy: nil, isActive: { true }) { _ in }
    }
    returned = true
    await waitForImageCheck { replacement.starts == 1 }
    ownerProgress?.cancel()
    precondition(replacement.transfer.isCancelled)

    for name in ["../private/photo.png", "/tmp/photo.png", "photo.png"] {
        precondition(ImageSelectionProcessor.fileName(name, fallbackExtension: "png") == "photo.png")
        precondition(ImageSelectionProcessor.jpegFileName(name) == "photo.jpg")
    }
    for name in ["", " ", ".", "..", "/"] {
        let raw = ImageSelectionProcessor.fileName(name, fallbackExtension: "png")
        let jpeg = ImageSelectionProcessor.jpegFileName(name)
        precondition(raw.hasPrefix("ios_") && raw.hasSuffix(".png") && !raw.contains("/"))
        precondition(jpeg.hasPrefix("ios_") && jpeg.hasSuffix(".jpg") && !jpeg.contains("/"))
    }
    print("PASS: Sequential provider files, source budget, cancellation, replacement and basename")
}
