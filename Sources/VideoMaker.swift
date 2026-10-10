import AVFoundation
import UIKit

/// Generates a tiny silent black mp4 on first launch so PiP has something to play.
enum VideoMaker {
    static func make(completion: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("pip_black.mp4")
        if FileManager.default.fileExists(atPath: url.path) { completion(url); return }

        DispatchQueue.global(qos: .utility).async {
            let w = 320, h = 240, fps = 10, frames = 20
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: w,
                    AVVideoHeightKey: h
                ])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: w,
                        kCVPixelBufferHeightKey as String: h
                    ])
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                for i in 0..<frames {
                    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
                    var pb: CVPixelBuffer?
                    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
                    guard let buf = pb else { continue }
                    CVPixelBufferLockBaseAddress(buf, [])
                    if let base = CVPixelBufferGetBaseAddress(buf) {
                        memset(base, 0, CVPixelBufferGetBytesPerRow(buf) * h)
                    }
                    CVPixelBufferUnlockBaseAddress(buf, [])
                    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
                }
                input.markAsFinished()
                writer.finishWriting {
                    completion(writer.status == .completed ? url : nil)
                }
            } catch {
                completion(nil)
            }
        }
    }
}
