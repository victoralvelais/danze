import AVFoundation

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
        if difference > 0 { try writeGap(difference, toward: source) }
        if difference >= 0 { try file.write(from: pcm) }
        else {
            edits.overlaps.record(Double(min(-difference, Int64(pcm.frameLength))) / format.sampleRate)
            guard -difference < Int64(pcm.frameLength) else { return }
            guard let tail = pcm.mixerCopy(from: Int(-difference)) else { throw TakeError("Could not trim overlapping mixer audio.") }
            try file.write(from: tail)
        }
        for ch in lastSamples.indices { lastSamples[ch] = source[ch][Int(pcm.frameLength) - 1] }
    }

    func completeGap(until host: Double) throws {
        let count = Int64(((host - origin) * file.processingFormat.sampleRate).rounded()) - file.framePosition
        guard count > 0 else { return }
        try writeGap(count, toward: nil)
        for ch in lastSamples.indices { lastSamples[ch] = 0 }
    }

    private func writeGap(_ frames: Int64, toward next: UnsafePointer<UnsafeMutablePointer<Float>>?) throws {
        let format = file.processingFormat
        edits.gaps.record(Double(frames) / format.sampleRate)
        let gap = MixerGap(length: frames, rate: format.sampleRate)
        guard let padding = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096), let channels = padding.floatChannelData
        else { throw TakeError("Could not align the audio gap.") }
        var filled: Int64 = 0
        while filled < frames {
            padding.frameLength = UInt32(min(4096, frames - filled))
            for ch in lastSamples.indices {
                gap.fill(UnsafeMutableBufferPointer(start: channels[ch], count: Int(padding.frameLength)),
                         at: filled, from: lastSamples[ch], to: next?[ch][0] ?? 0)
            }
            try file.write(from: padding)
            filled += Int64(padding.frameLength)
        }
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
