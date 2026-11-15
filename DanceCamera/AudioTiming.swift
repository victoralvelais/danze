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

    mutating func position(_ stamp: MixerStamp, count: Int, pcmRate: Double, followedBy following: MixerStamp? = nil) -> Double? {
        guard count > 0, pcmRate.isFinite, pcmRate > 0 else { return nil }
        let duration = Double(count) / pcmRate
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
                    return nextHost
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
    private var lastSamples: [Float]

    init(url: URL, format: AVAudioFormat, origin: Double) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.origin = origin
        lastSamples = Array(repeating: 0, count: Int(format.channelCount))
    }

    func append(_ pcm: AVAudioPCMBuffer, host: Double) throws {
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
        if difference > 0 {
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
            guard -difference < Int64(pcm.frameLength) else { return }
            guard let tail = pcm.mixerCopy(from: Int(-difference)) else { throw TakeError("Could not trim overlapping mixer audio.") }
            try file.write(from: tail)
        }
        for ch in lastSamples.indices { lastSamples[ch] = source[ch][Int(pcm.frameLength) - 1] }
    }
}

extension AVAudioPCMBuffer {
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
