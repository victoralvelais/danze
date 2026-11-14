import AVFoundation
import CoreVideo
import Foundation

// Use real compressed samples to catch trimming or an accidental second video encode.
@main
struct TakeExportCheck {
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: "TakeExportCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func video(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 192,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
        ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 192, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        try require(writer.startWriting(), "Unable to start fixture writer.")
        writer.startSession(atSourceTime: .zero)
        for i in 0..<48 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? TakeExport.ExportError("Writer stopped.") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(nil, 320, 192, kCVPixelFormatType_32BGRA, nil, &buffer)
            try require(result == kCVReturnSuccess, "Cannot allocate video frame.")
            guard let buffer else { throw TakeExport.ExportError("No pixel buffer.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(i * 4), CVPixelBufferGetBytesPerRow(buffer) * 192)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 24)), "Frame write failed.")
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, writer.error?.localizedDescription ?? "Video fixture failed.")
    }

    static func audio(_ url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 96_000)!
        buffer.frameLength = buffer.frameCapacity
        // Change frequency halfway through to expose wrong source offsets.
        for i in 0..<96_000 {
            let frequency = i < 48_000 ? 300.0 : 900.0
            buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * Double.pi * frequency * Double(i) / 48_000))
        }
        try file.write(from: buffer)
    }

    static func packets(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [Data] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        try require(reader.startReading(), "Cannot read compressed track.")
        var result: [Data] = []
        while let sample = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            try require(status == noErr, "Cannot read video sample.")
            result.append(data)
        }
        try require(reader.status == .completed && !result.isEmpty, "Incomplete video sample read.")
        return result
    }

    static func main() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mov = root.appendingPathComponent("camera.mov"), caf = root.appendingPathComponent("sound.caf")
        try await video(mov)
        try audio(caf)
        let original = AVURLAsset(url: mov), cam = try await original.loadTracks(withMediaType: .video).first!
        let frameData = try packets(original, cam)
        let duration = try await cam.load(.timeRange).duration.seconds
        let transform = try await cam.load(.preferredTransform)
        for (label, offset, includeAudio) in [("before", -0.5, true), ("after", 0.5, true), ("silent", 0, false)] {
            let dest = root.appendingPathComponent("\(label).mp4")
            let size = try await TakeExport.save(video: mov, audio: includeAudio ? caf : nil, audioOffset: offset, to: dest)
            let result = AVURLAsset(url: dest), pic = try await result.loadTracks(withMediaType: .video).first!
            let frames = try packets(result, pic)
            let t = try await pic.load(.timeRange), tx = try await pic.load(.preferredTransform)
            try require(size == CGSize(width: 320, height: 192) && tx == transform, "Video geometry changed.")
            try require(frames == frameData && abs(t.duration.seconds - duration) < 0.01, "Video frames changed in \(label).")
            let tracks = try await result.loadTracks(withMediaType: .audio)
            if includeAudio {
                try require(tracks.count == 1, "Missing soundtrack.")
                // Read the first real sample. A leading empty edit can be included in the track time range.
                let reader = try AVAssetReader(asset: result)
                let out = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
                ])
                reader.add(out)
                try require(reader.startReading(), "Cannot decode soundtrack.")
                // At camera time 0.80 s the early-start case should play 900 Hz, the late-start case 300 Hz.
                var crossings = 0, count = 0
                var previous: Float = 0
                while let sample = out.copyNextSampleBuffer() {
                    let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard let block = CMSampleBufferGetDataBuffer(sample),
                          let desc = CMSampleBufferGetFormatDescription(sample),
                          let fmt = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    guard length > 0, fmt.mChannelsPerFrame > 0 else { continue }
                    var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                    let status = values.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                    }
                    try require(status == noErr, "Cannot read audio samples.")
                    for i in stride(from: 0, to: values.count, by: Int(fmt.mChannelsPerFrame)) {
                        let when = start + Double(i / Int(fmt.mChannelsPerFrame)) / fmt.mSampleRate
                        if when < 0.75 || when >= 0.85 { continue }
                        if previous <= 0 && values[i] > 0 { crossings += 1 }
                        previous = values[i]
                        count += 1
                    }
                }
                try require(count > 4000 && abs(crossings - (offset < 0 ? 90 : 30)) <= 4, "Wrong soundtrack segment in \(label) (\(crossings) crossings).")
            } else { try require(tracks.isEmpty, "Unexpected audio in silent clip.") }
        }
        print("Verified full camera duration, unchanged compressed frames, rotation, and soundtrack alignment for three takes.")
    }
}
