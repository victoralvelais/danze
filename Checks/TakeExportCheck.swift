import AVFoundation
import CoreVideo
import Foundation

// Use real compressed samples to catch trimming or an accidental second video encode.
@main
struct TakeExportCheck {
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: "TakeExportCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
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
        while let sample = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) > 0 else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            try require(status == noErr, "Cannot read video sample.")
            result.append(data)
        }
        try require(reader.status == .completed && !result.isEmpty, "Incomplete video sample read (\(result.count) packets, status \(reader.status.rawValue), \(reader.error?.localizedDescription ?? "no error")).")
        return result
    }

    static func checkStream() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Checks/stream-tone.mp3"))
        var frames = 0, peak: Float = 0, crossings = 0, previous: Float = 0
        var rate = 0.0
        let decoder = try IncrementalDecoder { pcm in
            guard let samples = pcm.floatChannelData?[0] else { throw TakeError("Missing decoded audio.") }
            rate = pcm.format.sampleRate
            for i in 0..<Int(pcm.frameLength) {
                let value = samples[i]
                peak = max(peak, abs(value))
                if (22_050..<66_150).contains(frames + i), previous < 0 && value >= 0 { crossings += 1 }
                previous = value
            }
            frames += Int(pcm.frameLength)
        }
        var decodedBeforeEOF = false
        for start in stride(from: 0, to: fixture.count, by: 317) {
            let end = min(start + 317, fixture.count)
            try decoder.append(fixture.subdata(in: start..<end))
            if end <= fixture.count / 2 && frames > 0 { decodedBeforeEOF = true }
        }
        try decoder.finish()
        try require(decodedBeforeEOF && rate == 44_100 && frames >= 80_000 && peak > 0.03 &&
                    (436...444).contains(crossings), "The chunked two-second MP3 did not decode progressively (\(frames) frames, \(crossings) crossings).")
    }

    static func checkMixerTiming() throws {
        var clock = MixerTimeline()
        // 44.1 kHz, including a roughly 10 ms late callback every 300 ms.
        let rate = 44100.0, block = 441
        for i in 0..<400 {
            let frame = Int64((i + (i >= 200 ? 1 : 0)) * block)
            let jitter = i > 0 && i.isMultiple(of: 30) ? 0.011 : 0.0
            let place = clock.position(sample: frame, host: 10 + Double(frame) / rate + jitter, count: block, rate: rate)
            try require(Int64(((place - 10) * rate).rounded()) == frame, "Mixer callback jitter altered the sample timeline.")
        }
    }

    static func checkVariableSpeed(_ mov: URL, _ caf: URL, _ root: URL) async throws {
        let output = root.appendingPathComponent("speed.mp4")
        let events = [SpeedChange(host: 9, rate: 0.5), SpeedChange(host: 11, rate: 2)]
        _ = try await TakeExport.save(video: mov, audio: caf, audioOffset: 0, speeds: events, videoStart: 10, to: output)
        let asset = AVURLAsset(url: output)
        let image = try await asset.loadTracks(withMediaType: .video).first!
        let sound = try await asset.loadTracks(withMediaType: .audio).first!
        let v = try await image.load(.timeRange), a = try await sound.load(.timeRange)
        try require(abs(v.duration.seconds - 2.5) < 0.05 && abs(a.duration.seconds - 2.5) < 0.05,
                    "Variable speed durations differ. Video \(v.duration.seconds), audio \(a.duration.seconds).")
        let original = AVURLAsset(url: mov)
        let source = try await original.loadTracks(withMediaType: .video).first!
        try require(try packets(original, source) == packets(asset, image), "Retiming changed compressed video frames.")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: sound, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true
        ])
        reader.add(out)
        try require(reader.startReading(), "Could not read speed test audio.")
        var crossings = [0, 0], prior = [Float](repeating: 0, count: 2)
        while let sample = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) > 0,
                  let desc = CMSampleBufferGetFormatDescription(sample),
                  let fmt = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { continue }
            var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let ok = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: ptr.count, destination: ptr.baseAddress!)
            }
            try require(ok == 0, "Could not read samples.")
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let channels = Int(fmt.mChannelsPerFrame)
            for i in stride(from: 0, to: data.count, by: channels) {
                let time = t + Double(i / channels) / fmt.mSampleRate
                let window = time >= 0.15 && time < 0.35 ? 0 : time >= 1 && time < 1.2 ? 1 : -1
                if window < 0 { continue }
                if prior[window] <= 0 && data[i] > 0 { crossings[window] += 1 }
                prior[window] = data[i]
            }
        }
        try require(abs(crossings[0] - 60) <= 6 && abs(crossings[1] - 180) <= 8,
                    "Rate transitions or audio pitch changed unexpectedly: \(crossings).")
    }

    static func main() async throws {
        try checkMixerTiming()
        try checkStream()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mov = root.appendingPathComponent("camera.mov"), caf = root.appendingPathComponent("sound.caf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Checks/camera.mov"), to: mov)
        try audio(caf)
        try await checkVariableSpeed(mov, caf, root)
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
