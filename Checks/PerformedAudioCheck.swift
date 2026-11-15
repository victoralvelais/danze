import AVFoundation

enum PerformedAudioCheck {
    static func run(_ mov: URL, _ root: URL) async throws {
        let format = PerformedAudioBus.format, hz = format.sampleRate
        let engine = AVAudioEngine(), node = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        let bus = PerformedAudioBus(), feed = PerformedAudioFeed()
        engine.attach(node); engine.attach(pitch); bus.attach(to: engine)
        connectMusicPlayer(node, through: pitch, to: engine, format: format, rate: 0.75, mixer: bus.mixer)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2048)
        engine.prepare()
        try feed.install(on: bus.output)
        defer { engine.stop(); feed.shutdown() }
        let music = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(3 * hz))!
        music.frameLength = music.frameCapacity
        for ch in 0..<2 {
            for i in 0..<Int(music.frameLength) {
                let f = ch == 0 ? 440.0 : 670.0
                music.floatChannelData![ch][i] = Float(0.35 * sin(2 * .pi * f * Double(i) / hz))
            }
        }
        node.scheduleBuffer(music, at: nil, options: [], completionCallbackType: .dataRendered, completionHandler: nil)
        let events = feed.samples()
        let aac = root.appendingPathComponent("live-encoder.m4a")
        let encoder = Task.detached { try await encode(events, format: format, to: aac) }
        feed.speed(0.75, host: 0)
        try feed.begin()
        try engine.start()
        node.play()
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        var monitor = [[Float](), [Float]()], retries = 0
        let frames = 120_000
        while monitor[0].count < frames {
            let count = UInt32(min(2048, frames - monitor[0].count))
            let status = try engine.renderOffline(count, to: pcm)
            if status == .cannotDoInCurrentContext, retries < 32 { retries += 1; continue }
            try TakeExportCheck.require(status == .success && pcm.frameLength > 0, "Cannot render live monitor.")
            retries = 0
            for ch in 0..<2 { monitor[ch] += UnsafeBufferPointer(start: pcm.floatChannelData![ch], count: Int(pcm.frameLength)) }
            feed.flush()
            // The accelerated fixture still gives the independent encoder time to consume.
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let take = try feed.finish() else { throw TakeError("No soundtrack from the hardware program render.") }
        defer { try? FileManager.default.removeItem(at: take.url) }
        engine.stop(); feed.shutdown()
        let encoded = try await encoder.value
        try TakeExportCheck.require(encoded == frames, "Incremental encoder lost samples: \(encoded) vs \(frames).")
        let file = try AVAudioFile(forReading: take.url)
        try TakeExportCheck.require(file.length == Int64(frames), "Performed CAF changed the monitor duration: \(file.length).")
        let saved = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(frames))!
        try file.read(into: saved)
        for ch in 0..<2 {
            let recorded = UnsafeBufferPointer(start: saved.floatChannelData![ch], count: frames)
            try TakeExportCheck.require(recorded.elementsEqual(monitor[ch]), "Performed PCM differs from the monitored 0.75× render.")
        }
        try compareClocks(saved, root: root)
        try await checkLevels(aac, duration: 2.5)
        for restore in [false, true] {
            let target = root.appendingPathComponent("performed-\(restore).mp4")
            let export = try await TakeExport.save(video: mov, audio: take.url, audioOffset: -0.15,
                                                   speeds: take.speedChanges, restoreTempo: restore,
                                                   videoStart: take.firstAudioHostTime + 0.15, to: target)
            try TakeExportCheck.require(export.audioPath == (restore ? .mix(.noAnchor) : .performed), "Wrong tempo export path.")
            try await checkLevels(target, duration: restore ? 1.5 : 2)
        }
        print("Verified 0.75× hardware program PCM against monitored stereo, incremental AAC, performed MP4, and separate original-tempo mixer restoration.")
        try await checkPressureAndRestart(root)
    }

    private static func checkPressureAndRestart(_ root: URL) async throws {
        let format = PerformedAudioBus.format
        let e = AVAudioEngine(), p = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch(), bus = PerformedAudioBus()
        let feed = PerformedAudioFeed()
        e.attach(p); e.attach(pitch); bus.attach(to: e)
        connectMusicPlayer(p, through: pitch, to: e, format: format, rate: 1, mixer: bus.mixer)
        try e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        e.prepare()
        // Hold the consumer on this accelerated render, then drain at known boundaries.
        try feed.install(on: bus.output, drainInterval: .seconds(60))
        defer { e.stop(); feed.shutdown() }
        let slow = feed.samples()
        try feed.begin()
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        input.frameLength = input.frameCapacity
        for ch in 0..<2 {
            for i in 0..<48_000 { input.floatChannelData![ch][i] = Float(0.3 * sin(Double(i) * 0.09)) }
        }
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        func render(_ blocks: Int) throws {
            var done = 0, retries = 0
            while done < blocks {
                let status = try e.renderOffline(256, to: block)
                if status == .cannotDoInCurrentContext, retries < 32 { retries += 1; continue }
                try TakeExportCheck.require(status == .success && block.frameLength == 256, "Could not render pressure fixture.")
                retries = 0; done += 1
            }
        }
        p.scheduleBuffer(input, at: nil, options: [], completionCallbackType: .dataRendered, completionHandler: nil)
        try e.start(); p.play()
        try render(68); feed.flush()
        try render(2); feed.flush()
        let next = feed.samples() // Also ends the old stream if a pressure assertion regresses.
        var endedWithLoss = false
        do { for try await _ in slow {} } catch { endedWithLoss = true }
        try TakeExportCheck.require(endedWithLoss, "A stalled encoder silently lost buffered audio.")
        e.stop(); p.stop(); feed.uninstall()
        // A new song/route with a later presentation time uses the same open take.
        feed.setLatency(1.5)
        e.prepare(); try feed.install(on: bus.output, drainInterval: .seconds(60))
        p.scheduleBuffer(input, at: nil, options: [], completionCallbackType: .dataRendered, completionHandler: nil)
        try e.start(); p.play()
        try render(16); feed.flush()
        guard let take = try feed.finish() else { throw TakeError("A ring overrun discarded the whole take.") }
        defer { try? FileManager.default.removeItem(at: take.url) }
        e.stop(); feed.shutdown()
        var discontinuities = 0, frames = 0
        for try await event in next {
            switch event {
            case .discontinuity(let range):
                try TakeExportCheck.require(range.duration.seconds > 0.1, "Reinstalled graph lost its presentation gap.")
                discontinuities += 1
            case .samples(let sample): frames += CMSampleBufferGetNumSamples(sample)
            }
        }
        try TakeExportCheck.require(discontinuities == 1 && frames == 4096 && take.mixerEdits.gaps.count >= 2,
                                    "Ring loss or queue/route transition was not preserved and reported.")
        let file = try AVAudioFile(forReading: take.url)
        file.framePosition = file.length - 256
        try file.read(into: block, frameCount: 256)
        let tail = UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength))
        try TakeExportCheck.require(tail.contains { abs($0) > 0.01 }, "Audio after the discontinuity was lost.")
    }

    private static func encode(_ stream: AsyncThrowingStream<PerformedAudioEvent, Error>, format: AVAudioFormat, to url: URL) async throws -> Int {
        let encoder = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        encoder.add(input)
        try TakeExportCheck.require(encoder.startWriting(), "Could not start incremental AAC encoder.")
        var frames = 0, first: CMTime?
        for try await event in stream {
            guard case let .samples(sample) = event else { throw TakeError("Unexpected discontinuity in a continuous live stream.") }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let first {
                try TakeExportCheck.require(abs((pts - first).seconds * format.sampleRate - Double(frames)) < 1, "Live PTS drifted.")
            } else { first = pts; encoder.startSession(atSourceTime: pts) }
            var waits = 0
            while !input.isReadyForMoreMediaData && encoder.status == .writing && waits < 2000 {
                try await Task.sleep(for: .milliseconds(1)); waits += 1
            }
            try TakeExportCheck.require(input.append(sample), "Incremental AAC rejected PCM: \(encoder.error?.localizedDescription ?? "").")
            frames += CMSampleBufferGetNumSamples(sample)
        }
        guard frames > 0 else { throw TakeError("Encoder received no live audio.") }
        input.markAsFinished()
        await encoder.finishWriting()
        try TakeExportCheck.require(encoder.status == .completed, "Incremental AAC did not finish.")
        return frames
    }

    private static func checkLevels(_ url: URL, duration: Double) async throws {
        let samples = try await SourceAudioCheck.samples(url)
        try TakeExportCheck.require(abs(Double(samples.count) / 44_100 - duration) < 0.07, "Wrong exported AAC duration.")
        let count = 221 // 5 ms of decoded audio.
        for i in stride(from: 8820, to: min(samples.count, Int((duration - 0.12) * 44_100)) - count, by: count) {
            let energy = samples[i..<(i + count)].reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
            try TakeExportCheck.require(energy > 0.0016, "Dropout in \(url.lastPathComponent) near \(Double(i)/44100) s.")
        }
    }

    private static func compareClocks(_ played: AVAudioPCMBuffer, root: URL) throws {
        let format = played.format, hz = format.sampleRate, n = 480, count = 180
        var legacy = MixerTimeline(), current = PerformedClock()
        var prior: AVAudioPCMBuffer?
        let old = try MixerRecording(url: root.appendingPathComponent("old-jitter.caf"), format: format, origin: 10)
        let cleanURL = root.appendingPathComponent("live-jitter.caf")
        var clean: MixerRecording? = try MixerRecording(url: cleanURL, format: format, origin: 10)
        let stamps = (0..<count).map { i in
            MixerStamp(sample: Int64(i * n + ((30...31).contains(i) ? 720 : 0)), clockRate: hz, host: 10 + Double(i * n) / hz)
        }
        for i in stamps.indices {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(n))!
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<2 { pcm.floatChannelData![ch].update(from: played.floatChannelData![ch].advanced(by: i * n), count: n) }
            let next = i + 1 < count ? stamps[i + 1] : nil
            guard let oldTime = legacy.position(stamps[i], count: n, pcmRate: hz, followedBy: next,
                                                distinctOverlap: { pcm.differsFromPriorOverlap(prior, frames: $0, roundingFrames: $1) })
            else { throw TakeError("No legacy PTS.") }
            try old.append(pcm, host: oldTime)
            let t = current.position(start: Int64(i * n), frames: n, sample: Double(stamps[i].sample!), host: stamps[i].host,
                                     arrival: stamps[i].host!, latency: 0, earliest: nil)
            try clean?.append(pcm, host: t)
            prior = pcm
        }
        try TakeExportCheck.require(old.edits.gaps.count > 0 && old.edits.overlaps.count > 0 &&
                                    clean?.edits.gaps.count == 0 && clean?.edits.overlaps.count == 0,
                                    "Adjacent faulty timestamps did not distinguish the two capture paths.")
        clean = nil
        let reopened = try AVAudioFile(forReading: cleanURL)
        let whole = AVAudioPCMBuffer(pcmFormat: reopened.processingFormat, frameCapacity: UInt32(count * n))!
        try reopened.read(into: whole)
        for ch in 0..<2 {
            let actual = UnsafeBufferPointer(start: whole.floatChannelData![ch], count: Int(whole.frameLength))
            let expected = UnsafeBufferPointer(start: played.floatChannelData![ch], count: count * n)
            try TakeExportCheck.require(actual.elementsEqual(expected), "Render clock changed real performed samples on jitter.")
        }
        let end = 10 + Double(n * count) / hz
        let gap = current.position(start: Int64(n * count), frames: n, sample: Double(n * count + 960),
                                   host: end + 0.02, arrival: end + 0.02, latency: 0, earliest: nil)
        try TakeExportCheck.require(abs(gap - end - 0.02) < 1 / hz, "Genuine hardware stall was lost.")
        print("Before restoration, identical PCM and two bad stamps: 0.12.2 padded \(old.edits.gaps.summary) / trimmed \(old.edits.overlaps.summary); new capture was sample-exact.")
    }
}

// Frozen 0.12.2 callback-timestamp assembly for the before/after regression.
struct MixerStamp {
    let sample: Int64?
    let clockRate: Double
    let host: Double?
}

// Within a running mixer graph the sample clock identifies exactly adjacent buffers.
// The first presentation timestamp anchors that clock to the camera clock.
struct MixerTimeline {
    private var anchor: (sample: Int64, rate: Double, host: Double)?
    private var highestSample: Int64?
    private var nextHost: Double?
    private var previous: (stamp: MixerStamp, duration: Double)?
    private(set) var stampAdjustment = 0.0

    mutating func position(_ stamp: MixerStamp, count: Int, pcmRate: Double, followedBy following: MixerStamp? = nil,
                           distinctOverlap: (Int, Int) -> Bool = { _, _ in false }) -> Double? {
        stampAdjustment = 0
        guard count > 0, pcmRate.isFinite, pcmRate > 0 else { return nil }
        let duration = Double(count) / pcmRate
        defer { previous = (stamp, duration) }
        let host = stamp.host, clockRate = stamp.clockRate
        let point: Double
        if let sample = stamp.sample, clockRate.isFinite, clockRate > 0 {
            if let anchor, anchor.rate == clockRate {
                let predicted = anchor.host + (Double(sample) - Double(anchor.sample)) / clockRate
                // A single bad sample stamp can pad one block and trim the next.
                // Correct it only when the host and the following sample both
                // support contiguous PCM. A sustained clock jump keeps its gap.
                let tolerance = max(1 / pcmRate, 1 / clockRate) + 4 * predicted.ulp
                if let nextHost, predicted > nextHost + tolerance, let host,
                   abs(host - nextHost) < abs(host - predicted),
                   let following, following.clockRate == clockRate, let nextSample = following.sample,
                   abs(anchor.host + (Double(nextSample) - Double(anchor.sample)) / clockRate - (nextHost + duration)) <= tolerance {
                    self.nextHost = nextHost + duration
                    stampAdjustment = nextHost - predicted
                    return nextHost
                }
                // For a short backward stamp, require both neighboring sample positions
                // and host intervals to agree. A genuinely replayed slice of the last
                // buffer stays at its original position even when its host stamp is new.
                if let nextHost, predicted < nextHost - tolerance, let previous, nextHost - predicted <= previous.duration + tolerance,
                   pcmRate / clockRate <= 2, let host, let previousHost = previous.stamp.host,
                   let following, let followingHost = following.host, let followingSample = following.sample,
                   let previousSample = previous.stamp.sample, previous.stamp.clockRate == clockRate, following.clockRate == clockRate {
                    let early = nextHost - predicted
                    let previousEnd = anchor.host + (Double(previousSample) - Double(anchor.sample)) / clockRate + previous.duration
                    let followingStart = anchor.host + (Double(followingSample) - Double(anchor.sample)) / clockRate
                    let hostTolerance = max(tolerance, min(0.001, early / 4))
                    let roundingFrames = clockRate == pcmRate ? 0 : Int(ceil(pcmRate / clockRate))
                    if abs(previousEnd - nextHost) <= tolerance, abs(followingStart - (nextHost + duration)) <= tolerance,
                       abs(host - previousHost - previous.duration) <= hostTolerance,
                       abs(followingHost - host - duration) <= hostTolerance,
                       distinctOverlap(Int((early * pcmRate).rounded()), roundingFrames) {
                        self.nextHost = nextHost + duration
                        stampAdjustment = early
                        return nextHost
                    }
                }
                // Old or overlapping samples keep their old position. Re-anchor a
                // backward counter when the host clock places it in a new interval.
                if let highestSample, sample < highestSample, let host, let nextHost,
                   host >= nextHost - 1 / pcmRate, host - predicted > duration {
                    point = max(host, nextHost)
                    self.anchor = (sample, clockRate, point)
                    self.highestSample = sample
                } else {
                    // Fractional clock ticks can round adjacent PCM boundaries
                    // in opposite directions. Keep contiguous PCM sample-exact.
                    if let nextHost, abs(predicted - nextHost) <= tolerance { point = nextHost }
                    else { point = predicted }
                    highestSample = max(highestSample ?? sample, sample)
                }
            } else {
                // First timestamp or a new clock rate.
                guard let reference = host ?? nextHost else { return nil }
                point = max(reference, nextHost ?? reference)
                anchor = (sample, clockRate, point)
                highestSample = sample
            }
        } else {
            guard let host else { return nil }
            point = nextHost ?? host
        }
        nextHost = max(nextHost ?? point, point + duration)
        return point
    }
}

extension AVAudioPCMBuffer {
    func differsFromPriorOverlap(_ previous: AVAudioPCMBuffer?, frames: Int, roundingFrames: Int) -> Bool {
        guard let previous, frames > 0,
              previous.format.isEqual(format), !format.isInterleaved,
              let prior = previous.floatChannelData, let current = floatChannelData else { return false }
        // A lower-resolution sample clock may place the overlap one or two PCM frames
        // away from the rounded estimate. Preserve a genuine repeat at any such offset.
        let first = max(1, frames - roundingFrames), last = min(Int(previous.frameLength), frames + roundingFrames)
        guard first <= last else { return false }
        for length in first...last {
            let start = Int(previous.frameLength) - length
            let bytes = min(Int(frameLength), length) * MemoryLayout<Float>.stride
            if (0..<Int(format.channelCount)).allSatisfy({ memcmp(prior[$0].advanced(by: start), current[$0], bytes) == 0 }) { return false }
        }
        return true
    }

}
