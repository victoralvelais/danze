import AVFoundation

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

struct MixerEdits {
    struct Events {
        private(set) var count = 0
        private(set) var longest = 0.0
        mutating func record(_ seconds: Double) {
            count += 1
            longest = max(longest, seconds)
        }
        var summary: String { count == 0 ? "0" : String(format: "%d (largest %.2f ms)", count, longest * 1000) }
    }
    var early = Events(), late = Events(), gaps = Events(), overlaps = Events()

    var report: String {
        ["Mixer capture including pre-roll and tail",
         "Corrected early timestamps  \(early.summary)", "Corrected late timestamps  \(late.summary)",
         "Filled gaps  \(gaps.summary)", "Trimmed overlaps  \(overlaps.summary)"].joined(separator: "\n")
    }
}

// Shape only the missing PCM frames. Short holes interpolate between the real
// samples. Longer holes decay to silence and ramp back up over three ms per edge.
struct MixerGap {
    let length: Int64
    private let ramp: Double

    init(length: Int64, rate: Double) {
        self.length = length
        ramp = min(Double(length + 1), max(1, (rate * 0.003).rounded()))
    }

    func fill(_ samples: UnsafeMutableBufferPointer<Float>, at offset: Int64, from left: Float, to right: Float) {
        for i in samples.indices {
            let frame = offset + Int64(i)
            let leftWeight = max(0, 1 - Double(frame + 1) / ramp)
            let rightWeight = max(0, 1 - Double(length - frame) / ramp)
            samples[i] = left * Float(leftWeight) + right * Float(rightWeight)
        }
    }
}

// Places each mixer block at its camera-relative time in the CAF used for export.
final class MixerRecording {
    let file: AVAudioFile
    let origin: Double
    private(set) var edits = MixerEdits()
    private var lastSamples: [Float]

    init(url: URL, format: AVAudioFormat, origin: Double) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.origin = origin
        lastSamples = Array(repeating: 0, count: Int(format.channelCount))
    }

    func append(_ pcm: AVAudioPCMBuffer, host: Double, stampAdjustment: Double = 0) throws {
        guard pcm.frameLength > 0 else { return }
        let format = file.processingFormat
        guard format.sampleRate == pcm.format.sampleRate, format.channelCount == pcm.format.channelCount else {
            throw TakeError("Audio output format changed during the take.")
        }
        let offset = (host - origin) * format.sampleRate
        guard offset.isFinite, abs(offset) < 86400 * format.sampleRate else { throw TakeError("The audio clock changed unexpectedly.") }
        var difference = Int64(offset.rounded()) - file.framePosition
        // Ignore tiny timestamp-to-sample rounding jitter.
        if abs(difference) <= 1 { difference = 0 }
        guard let source = pcm.floatChannelData else { throw TakeError("Could not read the mixer samples.") }
        if stampAdjustment > 0 { edits.early.record(stampAdjustment) }
        if stampAdjustment < 0 { edits.late.record(-stampAdjustment) }
        if difference > 0 {
            edits.gaps.record(Double(difference) / format.sampleRate)
            let gap = MixerGap(length: difference, rate: format.sampleRate)
            guard let padding = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                  let channels = padding.floatChannelData else { throw TakeError("Could not align the audio gap.") }
            var filled: Int64 = 0
            while filled < gap.length {
                padding.frameLength = UInt32(min(4096, gap.length - filled))
                for ch in lastSamples.indices {
                    gap.fill(UnsafeMutableBufferPointer(start: channels[ch], count: Int(padding.frameLength)),
                             at: filled, from: lastSamples[ch], to: source[ch][0])
                }
                try file.write(from: padding)
                filled += Int64(padding.frameLength)
            }
        }
        if difference >= 0 { try file.write(from: pcm) }
        else {
            edits.overlaps.record(Double(min(-difference, Int64(pcm.frameLength))) / format.sampleRate)
            guard -difference < Int64(pcm.frameLength) else { return }
            guard let tail = pcm.mixerCopy(from: Int(-difference)) else { throw TakeError("Could not trim overlapping mixer audio.") }
            try file.write(from: tail)
        }
        for ch in lastSamples.indices { lastSamples[ch] = source[ch][Int(pcm.frameLength) - 1] }
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

    func mixerCopy(from start: Int = 0) -> AVAudioPCMBuffer? {
        guard start >= 0, start < Int(frameLength) else { return nil }
        let count = Int(frameLength) - start
        guard let input = floatChannelData,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)),
              let output = pcm.floatChannelData else { return nil }
        pcm.frameLength = UInt32(count)
        for channel in 0..<Int(format.channelCount) {
            output[channel].update(from: input[channel].advanced(by: start), count: count)
        }
        return pcm
    }
}

struct SpeedChange {
    let host: Double
    let rate: Double
}

struct TakeSpeedRange {
    let start: Double
    let end: Double
    let rate: Double

    static func ranges(changes: [SpeedChange], videoStart: Double, duration: Double) -> [Self] {
        var start = 0.0, rate = 1.0, result: [Self] = []
        for change in changes.sorted(by: { $0.host < $1.host }) {
            let time = min(duration, max(0, change.host - videoStart))
            if time > start { result.append(Self(start: start, end: time, rate: rate)) }
            start = time
            rate = change.rate
        }
        if duration > start { result.append(Self(start: start, end: duration, rate: rate)) }
        return result
    }
}
