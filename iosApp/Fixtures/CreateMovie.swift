import AVFoundation
import CoreVideo
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
writer.add(input)
precondition(writer.startWriting())
writer.startSession(atSourceTime: .zero)
var pixel: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
precondition(adaptor.append(pixel!, withPresentationTime: .zero))
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
precondition(finished.wait(timeout: .now() + 15) == .success)
precondition(writer.status == .completed, writer.error?.localizedDescription ?? "MOV encoding failed")
