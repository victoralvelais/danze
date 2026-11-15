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
            let stamp = MixerStamp(sample: frame, clockRate: rate, host: 10 + Double(frame) / rate + jitter)
            guard let place = clock.position(stamp, count: block, pcmRate: rate) else { throw TakeError("Missing block position.") }
            try require(Int64(((place - 10) * rate).rounded()) == frame, "Mixer callback jitter altered the sample timeline.")
        }
        // The sample counter can have a different rate from the copied PCM. Only
        // the first block supplies a host anchor. All following audio is usable.
        for (clockRate, pcmRate) in [(44_100.0, 48_000.0), (48_000.0, 44_100.0)] {
            var mixedClock = MixerTimeline()
            let frames = 1024
            for i in 0..<256 {
                let start = i * frames
                let stamp = Int64((Double(start) * clockRate / pcmRate).rounded())
                let time = MixerStamp(sample: stamp, clockRate: clockRate, host: i == 0 ? 20 : nil)
                let place = mixedClock.position(time, count: frames, pcmRate: pcmRate)
                guard let place else { throw TakeError("Dropped a sample-only mixer block after anchoring.") }
                let written = Int(((place - 20) * pcmRate).rounded())
                try require(abs(written - start) <= 1, "Mixed-rate clocks created an artificial gap or overlap.")
            }
        }
        var overlaps = MixerTimeline()
        func at(_ sample: Int64, _ host: Double? = nil) throws -> Int {
            guard let time = overlaps.position(MixerStamp(sample: sample, clockRate: 48_000, host: host), count: 480, pcmRate: 48_000)
            else { throw TakeError("Missing anchored mixer timestamp.") }
            return Int(((time - 20) * 48_000).rounded())
        }
        try require(overlaps.position(MixerStamp(sample: 0, clockRate: 48_000, host: nil), count: 480, pcmRate: 48_000) == nil,
                    "An unanchored sample timestamp invented a camera time.")
        let offsets = try [at(960, 20), at(960), at(1200), at(1680), at(1200, 20.005), at(0, 20.1)]
        try require(offsets == [0, 0, 240, 720, 240, 4800], "Duplicated, overlapping or restarted sample clocks were misaligned.")
        for clockRate in [44_100.0, 48_000.0] {
            for permanentGap in [false, true] {
                var clock = MixerTimeline(), written = 0
                let frames = 480
                let stamps = (0..<20).map { i -> MixerStamp in
                    let frame = i * frames + (i == 8 || (permanentGap && i > 8) ? 720 : 0)
                    let tick = Int64((Double(frame) * clockRate / 48_000).rounded())
                    return MixerStamp(sample: tick, clockRate: clockRate, host: 10 + Double(i * frames) / 48_000)
                }
                for i in stamps.indices {
                    let next = i + 1 < stamps.count ? stamps[i + 1] : nil
                    guard let time = clock.position(stamps[i], count: frames, pcmRate: 48_000, followedBy: next)
                    else { throw TakeError("Missing mixer block while testing a clock jump.") }
                    let difference = Int(((time - 10) * 48_000).rounded()) - written
                    if permanentGap && i == 8 {
                        try require(abs(difference - 720) <= 1, "A real 15 ms gap changed duration.")
                        written += difference
                    } else {
                        try require(abs(difference) <= 1, "Contiguous PCM needed a splice after a clock jump.")
                    }
                    written += frames
                }
            }
        }
    }

    static func checkBackwardStamps(_ root: URL) throws {
        let hz = 48_000.0, n = 1024
        let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 2)!
        let grid = (0..<5).map { $0 * n }
        let hosts = grid.map { Optional($0) }
        func check(_ label: String, stamps: [Int], hosts: [Int?], content: [Int], positions: [Int],
                   clockRate: Double = 48_000, corrected: Int = 0, filled: Int = 0, trimmed: Int = 0) throws {
            let path = root.appendingPathComponent(label + ".caf")
            let recording = try MixerRecording(url: path, format: format, origin: 10)
            var timeline = MixerTimeline(), prior: AVAudioPCMBuffer?
            let times = zip(stamps, hosts).map { stamp, host in
                MixerStamp(sample: Int64((Double(stamp) * clockRate / hz).rounded()), clockRate: clockRate, host: host.map { 10 + Double($0) / hz })
            }
            for i in times.indices {
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(n))!
                pcm.frameLength = pcm.frameCapacity
                // Left is silent. Only the right channel can rule out repeated PCM.
                pcm.floatChannelData![0].update(repeating: 0, count: n)
                for j in 0..<n { pcm.floatChannelData![1][j] = Float(content[i] + j) / 8192 }
                let next = i + 1 < times.count ? times[i + 1] : nil
                guard let point = timeline.position(times[i], count: n, pcmRate: hz, followedBy: next,
                                                     distinctOverlap: { pcm.differsFromPriorOverlap(prior, frames: $0, roundingFrames: $1) })
                else { throw TakeError("Missing timestamp in \(label).") }
                let rounding = clockRate == hz ? 0 : 1
                try require(abs(Int(((point - 10) * hz).rounded()) - positions[i]) <= rounding, "Incorrect placement in \(label), buffer \(i).")
                try recording.append(pcm, host: point, stampAdjustment: timeline.stampAdjustment)
                prior = pcm
            }
            let edits = recording.edits
            try require(edits.early.count == corrected && edits.gaps.count == (filled > 0 ? 1 : 0) &&
                        edits.overlaps.count == (trimmed > 0 ? 1 : 0) &&
                        Int((edits.gaps.longest * hz).rounded()) == filled &&
                        Int((edits.overlaps.longest * hz).rounded()) == trimmed, "Incorrect mixer report for \(label).")
        }
        for slip in [640, n] {
            var stamps = grid
            stamps[2] -= slip
            try check("new-\(slip)", stamps: stamps, hosts: hosts, content: grid, positions: grid, corrected: 1)
            // Same timestamps, but the audio actually contains repeated samples.
            try check("replayed-\(slip)", stamps: stamps, hosts: hosts, content: stamps, positions: stamps, filled: slip, trimmed: slip)
            var late = hosts
            late[1] = n + 200
            try check("late-prior-\(slip)", stamps: stamps, hosts: late, content: grid, positions: stamps, filled: slip, trimmed: slip)
            var missing = hosts
            missing[3] = nil
            try check("missing-next-\(slip)", stamps: stamps, hosts: missing, content: grid, positions: stamps, filled: slip, trimmed: slip)
        }
        let reset = [20 * n, 21 * n, 0, n, 2 * n]
        try check("clock-reset", stamps: reset, hosts: hosts, content: grid, positions: grid)
        let repeated = [0, n, 2 * n - 651, 3 * n, 4 * n]
        try check("rounded-replay", stamps: repeated, hosts: hosts, content: repeated, positions: repeated,
                  clockRate: 44_100, filled: 652, trimmed: 652)
    }

    static func checkGapEdges() throws {
        // Start and end at opposite waveform peaks. A zero-filled hole would
        // produce a full-scale step at both ends. Fill in chunks, like the CAF writer.
        for length in [2, 48, 180, 12_000] {
            let gap = MixerGap(length: Int64(length), rate: 48_000)
            var waveform: [Float] = [0.8]
            var offset = 0
            while offset < length {
                var chunk = Array(repeating: Float.nan, count: min(4096, length - offset))
                chunk.withUnsafeMutableBufferPointer { gap.fill($0, at: Int64(offset), from: 0.8, to: -0.8) }
                waveform.append(contentsOf: chunk)
                offset += chunk.count
            }
            waveform.append(-0.8)
            let maxStep = zip(waveform, waveform.dropFirst()).map { abs($1 - $0) }.max()!
            let limit: Float = 1.6 / Float(min(length + 1, 144))
            try require(waveform.count == length + 2 && maxStep <= limit + 0.0001, "An audio gap introduced a sharp edge.")
            if length > 4096 { try require(waveform[length / 2] == 0, "The interior of a long audio gap must remain silent.") }
        }
    }

    static func writeMixerTone(to url: URL) throws -> [[Float]] {
        let rate = 44_100.0, block = 441, count = 200
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let recording = try MixerRecording(url: url, format: format, origin: 10)
        var timeline = MixerTimeline()
        var prior: AVAudioPCMBuffer?
        var expected = [[Float](), [Float]()]
        let stamps = (0..<count).map { i -> MixerStamp in
            // Alternate early and late stamps. The stamp clock runs at 48 kHz
            // and the PCM at 44.1 kHz. Several other blocks have no host stamp.
            let jump = i >= 33 && (i - 33).isMultiple(of: 30)
            let offset = jump ? ((i - 33).isMultiple(of: 60) ? 828 : -320) : 0
            return MixerStamp(sample: Int64(i * 480 + offset), clockRate: 48_000,
                              host: i % 30 == 15 ? nil : 10 + Double(i) / 100)
        }
        for i in stamps.indices {
            let following = i + 1 < stamps.count ? stamps[i + 1] : nil
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(block))!
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<2 {
                for j in 0..<block {
                    let angle = 2 * Double.pi * Double(i * block + j) * (ch == 0 ? 440 : 660) / rate
                    let value = Float(0.35 * sin(angle))
                    pcm.floatChannelData![ch][j] = value
                    expected[ch].append(value)
                }
            }
            guard let time = timeline.position(stamps[i], count: block, pcmRate: rate, followedBy: following,
                                               distinctOverlap: { pcm.differsFromPriorOverlap(prior, frames: $0, roundingFrames: $1) }) else {
                throw TakeError("The recorder lost a timed tone block.")
            }
            try recording.append(pcm, host: time, stampAdjustment: timeline.stampAdjustment)
            prior = pcm
        }
        try require(recording.edits.late.count == 3 && recording.edits.early.count == 3 &&
                    recording.edits.gaps.count == 0 && recording.edits.overlaps.count == 0, "Unexpected tone capture report.")
        return expected
    }

    static func checkExportedTone(_ mov: URL, _ root: URL) async throws {
        let caf = root.appendingPathComponent("mixer.caf")
        let expected = try writeMixerTone(to: caf)
        let captured = try AVAudioFile(forReading: caf)
        try require(captured.length == Int64(expected[0].count), "Clock corrections changed the captured duration.")
        let raw = AVAudioPCMBuffer(pcmFormat: captured.processingFormat, frameCapacity: UInt32(captured.length))!
        try captured.read(into: raw)
        for ch in 0..<2 {
            let samples = UnsafeBufferPointer(start: raw.floatChannelData![ch], count: Int(raw.frameLength))
            try require(samples.elementsEqual(expected[ch]), "A timestamp fault changed real captured audio.")
        }

        let target = root.appendingPathComponent("mixer-retimed.mp4")
        _ = try await TakeExport.save(video: mov, audio: caf, audioOffset: 0,
                                      speeds: [SpeedChange(host: 10, rate: 0.85)], videoStart: 10, to: target)
        let asset = AVURLAsset(url: target)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TakeError("Missing exported tone.") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(out)
        try require(reader.startReading(), "Could not decode the exported tone.")
        // A 15 ms dropout contains at least one complete 5 ms bin. Exclude
        // the first and last 100 ms for TimePitch startup and AAC boundaries.
        let bins = 340  // Two seconds of video at 0.85×, in 5 ms bins.
        var energy = Array(repeating: [0.0, 0.0], count: bins)
        var counts = Array(repeating: 0, count: bins)
        while let sample = out.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample),
                  let desc = CMSampleBufferGetFormatDescription(sample),
                  let fmt = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                  fmt.mChannelsPerFrame == 2 else { throw TakeError("Expected decoded stereo PCM.") }
            let bytes = CMBlockBufferGetDataLength(data)
            guard bytes > 0 else { continue }
            var values = Array(repeating: Float.zero, count: bytes / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try require(status == noErr, "Could not read decoded tone samples.")
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for f in 0..<(values.count / 2) {
                let bin = Int(floor((start + Double(f) / fmt.mSampleRate) * 200))
                guard counts.indices.contains(bin) else { continue }
                counts[bin] += 1
                for ch in 0..<2 {
                    let v = Double(values[2 * f + ch])
                    energy[bin][ch] += v * v
                }
            }
        }
        try require(reader.status == .completed, "The exported tone could not be decoded completely.")
        for bin in 20..<(bins - 20) {
            try require(counts[bin] > 0, "Missing AAC samples at \(bin * 5) ms.")
            for ch in 0..<2 {
                let rms = sqrt(energy[bin][ch] / Double(counts[bin]))
                // The reference sinusoid has RMS 0.247. Fail on a >12 dB dip.
                try require(rms > 0.062, "Exported channel \(ch + 1) dipped at \(bin * 5) ms (RMS \(rms)).")
            }
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
        try checkGapEdges()
        try checkStream()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkBackwardStamps(root)
        let mov = root.appendingPathComponent("camera.mov"), caf = root.appendingPathComponent("sound.caf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Checks/camera.mov"), to: mov)
        try await SourceAudioCheck.checkPlayback(mov, root)
        try await SourceAudioCheck.checkSource(mov, root)
        try await SourceAudioCheck.checkAlignment(mov, root)
        try await PerformedAudioCheck.run(mov, root)
        try await checkExportedTone(mov, root)
        try audio(caf)
        try await checkVariableSpeed(mov, caf, root)
        let original = AVURLAsset(url: mov), cam = try await original.loadTracks(withMediaType: .video).first!
        let frameData = try packets(original, cam)
        let duration = try await cam.load(.timeRange).duration.seconds
        let transform = try await cam.load(.preferredTransform)
        for (label, offset, includeAudio) in [("before", -0.5, true), ("after", 0.5, true), ("silent", 0, false)] {
            let dest = root.appendingPathComponent("\(label).mp4")
            let export = try await TakeExport.save(video: mov, audio: includeAudio ? caf : nil, audioOffset: offset, to: dest)
            let result = AVURLAsset(url: dest), pic = try await result.loadTracks(withMediaType: .video).first!
            let frames = try packets(result, pic)
            let t = try await pic.load(.timeRange), tx = try await pic.load(.preferredTransform)
            try require(export.size == CGSize(width: 320, height: 192) && tx == transform, "Video geometry changed.")
            try require(export.audioPath == (includeAudio ? .mix(.noAnchor) : .none), "Wrong audio report for \(label).")
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
