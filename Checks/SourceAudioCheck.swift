import AVFoundation

enum SourceAudioCheck {
    private static let hz = 44_100.0
    private static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw TakeError(message) }
    }

    // Decode the exported AAC against its actual presentation timestamps.
    private static func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TakeError("Missing output audio.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: hz, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try require(reader.startReading(), "Could not decode test audio.")
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(data)
            guard bytes > 0 else { continue }
            var pcm = [Float](repeating: 0, count: bytes / 4)
            let status = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            try require(status == noErr, "Unreadable output audio.")
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try require(time.isFinite && abs(time) < 10, "Unexpected sample presentation time.")
            let frame = Int((time * hz).rounded())
            if frame > samples.count { samples += [Float](repeating: 0, count: frame - samples.count) }
            samples.append(contentsOf: pcm.dropFirst(max(0, samples.count - frame)))
        }
        try require(reader.status == .completed && !samples.isEmpty, "Incomplete output audio.")
        return samples
    }

    private static func rms(_ data: [Float], at time: Double, width: Double = 0.005) -> Double {
        let start = Int(time * hz), end = min(data.count, Int((time + width) * hz))
        guard start >= 0, start < end else { return 0 }
        return sqrt(data[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start))
    }

    private static func frequency(_ data: [Float], at time: Double) -> Double {
        let start = Int(time * hz), end = min(data.count, Int((time + 0.025) * hz))
        guard start >= 0, end > start + 1 else { return 0 }
        var count = 0
        for i in (start + 1)..<end where data[i - 1] <= 0 && data[i] > 0 { count += 1 }
        return Double(count) * hz / Double(end - start)
    }

    private static func renderPlayer(buffers: [AVAudioPCMBuffer], reference: URL?, rate: Double, to url: URL) throws {
        let format = buffers[0].format
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        engine.attach(player); engine.attach(pitch)
        connectMusicPlayer(player, through: pitch, to: engine, format: format, rate: rate)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let file = try reference.map { try AVAudioFile(forReading: $0) }
        if let file { player.scheduleFile(file, at: nil) }
        else {
            for pcm in buffers {
                player.scheduleBuffer(pcm, at: nil, options: [], completionCallbackType: .dataRendered, completionHandler: nil)
            }
        }
        try engine.start()
        defer { engine.stop() }
        player.play()
        let out = try AVAudioFile(forWriting: url, settings: format.settings)
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var retries = 0
        while out.framePosition < Int64(2 * hz) {
            let n = UInt32(min(1024, Int64(2 * hz) - out.framePosition))
            let status = try engine.renderOffline(n, to: block)
            if status == .cannotDoInCurrentContext && retries < 32 { retries += 1; continue }
            try require(status == .success && block.frameLength > 0, "Cannot render streamed player.")
            retries = 0
            try out.write(from: block)
        }
    }

    static func checkPlayback(_ mov: URL, _ root: URL) async throws {
        let mp3 = URL(fileURLWithPath: "Checks/stream-tone.mp3")
        let data = try Data(contentsOf: mp3)
        var buffers: [AVAudioPCMBuffer] = []
        let decoder = try IncrementalDecoder { buffers.append($0) }
        for i in stride(from: 0, to: data.count, by: 317) {
            try decoder.append(data.subdata(in: i..<min(i + 317, data.count)))
        }
        try decoder.finish()
        try require(buffers.count > 2, "No progressive audio to schedule.")
        for rate in [1.0, 0.85] {
            let baseline = root.appendingPathComponent("continuous-\(rate).caf")
            let streamed = root.appendingPathComponent("progressive-\(rate).caf")
            try renderPlayer(buffers: buffers, reference: mp3, rate: rate, to: baseline)
            try renderPlayer(buffers: buffers, reference: nil, rate: rate, to: streamed)
            let reference = try await samples(baseline)
            for restore in (rate == 1 ? [false] : [false, true]) {
                let out = root.appendingPathComponent("stream-export-\(rate)-\(restore).mp4")
                _ = try await TakeExport.save(video: mov, audio: streamed, audioOffset: 0,
                                              speeds: restore ? [SpeedChange(host: 0, rate: rate)] : [], to: out)
                let result = try await samples(out)
                for i in 35..<360 {
                    let t = Double(i) * 0.005
                    let normal = rms(reference, at: t)
                    let exported = rms(result, at: restore ? t * rate : t)
                    try require(normal > 0.02 && exported > normal * 0.35,
                                "Progressive playback/export dropout at \(t)s, speed \(rate), restore \(restore).")
                }
            }
        }
    }

    static func checkSource(_ mov: URL, _ root: URL) async throws {
        let rate = 0.85, start = 10.2
        let begin = PlayerAnchor(host: 10, song: 0.55, rate: rate, route: ["fixture"])
        let end = PlayerAnchor(host: 12.3, song: 0.55 + 2.3 * rate, rate: rate, route: ["fixture"])
        let capture = SourceAudioCapture()
        let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 1)!
        let damaged = root.appendingPathComponent("lost-mixer-audio.caf")
        var mix: AVAudioFile? = try AVAudioFile(forWriting: damaged, settings: format.settings)
        for i in 0..<310 {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
            pcm.frameLength = 441
            for j in 0..<441 {
                let t = Double(i * 441 + j) / hz
                let tone = t < 1.55 ? 300.0 : 900.0
                pcm.floatChannelData![0][j] = Float(0.35 * sin(2 * .pi * t * tone))
            }
            capture.append(pcm)
            if i == 300 { capture.begin(begin, stableFrom: 9) }
            if i < 200 {
                let mixed = pcm.mixerCopy()!
                if (50..<52).contains(i) || (80..<82).contains(i) {
                    mixed.floatChannelData![0].update(repeating: 0, count: 441)
                }
                try mix?.write(from: mixed)
            }
        }
        mix = nil
        guard let source = capture.finish(end) else { throw TakeError("The decoded source recording was lost.") }
        let srcStart = 0.55 + 0.2 * rate
        try require(abs((source.offset(videoStart: start, duration: 2) ?? -5) - srcStart) < 0.00001, "Wrong source offset.")
        try require(source.offset(videoStart: start, duration: 5) == nil, "Accepted uncovered source audio.")
        let short = SourceSoundtrack(file: source.file, first: begin, last: end, stableFrom: 9,
                                     firstFrame: 0, frameCount: 44_100, sampleRate: hz)
        try require(short.offset(videoStart: start, duration: 2) == nil, "Accepted an incomplete source file.")
        let drift = PlayerAnchor(host: end.host, song: end.song + 0.1, rate: rate, route: begin.route)
        let drifting = SourceSoundtrack(file: source.file, first: begin, last: drift, stableFrom: 9,
                                        firstFrame: 0, frameCount: source.frameCount, sampleRate: hz)
        try require(drifting.offset(videoStart: start, duration: 2) == nil, "Accepted inconsistent player clocks.")
        for restore in [false, true] {
            let out = root.appendingPathComponent("recovered-\(restore).mp4")
            let export = try await TakeExport.save(video: mov, audio: damaged, audioOffset: 0,
                                                   speeds: [SpeedChange(host: 8, rate: 1.5), SpeedChange(host: 9, rate: rate),
                                                            SpeedChange(host: 20, rate: 2)], restoreTempo: restore,
                                                   videoStart: start, source: source, to: out)
            try require(export.audioPath == .source, "Incorrect decoded source report.")
            try require(export.recordedRates == [rate], "Reported rates outside the captured picture.")
            let data = try await samples(out)
            let marker = (1.55 - srcStart) / (restore ? 1 : rate)
            try require(abs(frequency(data, at: marker - 0.075) - 300) < 80 &&
                        abs(frequency(data, at: marker + 0.05) - 900) < 90, "Source marker lost sync or pitch.")
            for i in 25..<(Int((restore ? 2 * rate : 2) / 0.005) - 25) {
                try require(rms(data, at: Double(i) * 0.005) > 0.06, "Missing source samples survived the export.")
            }
        }
        let changed = PlayerAnchor(host: end.host, song: end.song, rate: rate, route: ["other"])
        capture.begin(begin, stableFrom: 9)
        guard let mismatched = capture.finish(changed) else { throw TakeError("Missing transport-change fixture.") }
        try require(mismatched.offset(videoStart: start, duration: 2) == nil, "Accepted a changed route.")
        capture.begin(begin, stableFrom: 9)
        capture.cancel()
        try require(capture.finish(end) == nil && capture.fallback == .transport, "A transport change retained the source take or lost its reason.")
        let out = root.appendingPathComponent("intentional-fallback.mp4")
        let export = try await TakeExport.save(video: mov, audio: damaged, audioOffset: 0, videoStart: start, source: mismatched, to: out)
        try require(export.audioPath == .mix(.alignment), "Wrong reason for mixer fallback.")
        let fallback = try await samples(out)
        try require(rms(fallback, at: 0.505) < 0.055 && rms(fallback, at: 0.55) > 0.1, "Did not preserve the live mix on fallback.")
    }
}
