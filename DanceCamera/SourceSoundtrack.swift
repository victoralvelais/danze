import AVFoundation

func connectMusicPlayer(_ node: AVAudioPlayerNode, through pitch: AVAudioUnitTimePitch,
                        to engine: AVAudioEngine, format: AVAudioFormat, rate: Double) {
    engine.connect(node, to: pitch, format: format)
    engine.connect(pitch, to: engine.mainMixerNode, format: format)
    pitch.rate = Float(rate)
}

struct PlayerAnchor {
    let host: Double       // Audible presentation time in the camera's host clock.
    let song: Double       // Position in decoded source seconds.
    let rate: Double
    let route: [String]
}

enum SourceFallback: String {
    case noAnchor = "No reliable source timing at the start or end."
    case transport = "Playback, speed or output changed during capture."
    case writer = "Decoded source audio could not be written in full."
    case alignment = "Source timing, speed or frame coverage did not match the video."
    case render = "Source rendering or encoding failed."
}

final class SourceAudioFile {
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct SourceSoundtrack {
    let file: SourceAudioFile
    let first: PlayerAnchor
    let last: PlayerAnchor
    let stableFrom: Double
    let firstFrame: Int64
    let frameCount: Int64
    let sampleRate: Double

    func offset(videoStart: Double, duration: Double) -> Double? {
        let speed = first.rate
        guard speed > 0, first.rate == last.rate, first.route == last.route,
              sampleRate > 0, duration > 0, videoStart >= stableFrom,
              last.host > first.host, last.song > first.song,
              videoStart >= first.host - 1, videoStart + duration <= last.host + 0.1 else { return nil }
        // Reject a stale render timestamp or clocks drifting more than half a
        // 30 fps frame over the take. Constant latency is already in both anchors.
        let error = (last.song - first.song) / speed - (last.host - first.host)
        guard abs(error) <= 1.0 / 60 else { return nil }
        let start = first.song + (videoStart - first.host) * speed - Double(firstFrame) / sampleRate
        guard start >= 0, start + duration * speed <= Double(frameCount) / sampleRate else { return nil }
        return start
    }
}

// Only SoundtrackPlayer's serial queue calls these methods. Samples come from
// the decoder, before the player, time-pitch unit, hardware route and mixer tap.
final class SourceAudioCapture {
    private struct Block {
        let start: Int64
        let pcm: AVAudioPCMBuffer
        var end: Int64 { start + Int64(pcm.frameLength) }
        var bytes: Int {
            let planes = pcm.format.isInterleaved ? 1 : Int(pcm.format.channelCount)
            return Int(pcm.frameCapacity) * Int(pcm.format.streamDescription.pointee.mBytesPerFrame) * planes
        }
    }
    private var history: [Block] = []
    private var decoded: Int64 = 0
    private var rendered: Int64 = 0
    private var historyBytes = 0
    private var take: Writer?
    private(set) var fallback = SourceFallback.noAnchor

    func append(_ pcm: AVAudioPCMBuffer) {
        let block = Block(start: decoded, pcm: pcm)
        decoded = block.end
        history.append(block)
        historyBytes += block.bytes
        // Keep recent audible material as well as the player's scheduled lead.
        // Cap memory if the server delivers an unusually large chunk all at once.
        let hz = pcm.format.sampleRate
        let cutoff = max(rendered - Int64(3 * hz), decoded - Int64(12 * hz))
        while let first = history.first, first.end <= cutoff || historyBytes > 16 * 1024 * 1024 {
            historyBytes -= first.bytes
            history.removeFirst()
        }
        take?.enqueue([block])
    }

    func didRender(_ frames: Int64) { rendered += frames }

    func reset() {
        cancel()
        history.removeAll()
        decoded = 0
        rendered = 0
        historyBytes = 0
    }

    func begin(_ anchor: PlayerAnchor?, stableFrom: Double) {
        cancel()
        fallback = .noAnchor
        guard let anchor, let first = history.first else { return }
        let writer = Writer(anchor: anchor, stableFrom: stableFrom, first: first)
        writer.enqueue(history)
        take = writer
    }

    func cancel() {
        if take != nil { fallback = .transport }
        take = nil
    }

    func finish(_ end: PlayerAnchor?) -> SourceSoundtrack? {
        defer { self.take = nil }
        guard let take else { return nil }
        guard let end else { fallback = .noAnchor; return nil }
        let result = take.finish(end)
        if result == nil { fallback = .writer }
        return result
    }

    private final class Writer {
        let destination = SourceAudioFile()
        let anchor: PlayerAnchor
        let stableFrom: Double
        let start: Int64
        let format: AVAudioFormat
        private let queue = DispatchQueue(label: "DanceCamera.source-audio.write", qos: .utility)
        private let slots = DispatchSemaphore(value: 64)
        private var accepting = true // Owned by the player queue.
        private var file: AVAudioFile?
        private var failed = false   // Owned by the writer queue.

        init(anchor: PlayerAnchor, stableFrom: Double, first: Block) {
            self.anchor = anchor
            self.stableFrom = stableFrom
            start = first.start
            format = first.pcm.format
        }

        func enqueue(_ blocks: [Block]) {
            guard accepting else { return }
            guard slots.wait(timeout: .now()) == .success else { accepting = false; return }
            queue.async {
                defer { self.slots.signal() }
                guard !self.failed else { return }
                do {
                    if self.file == nil { self.file = try AVAudioFile(forWriting: self.destination.url, settings: self.format.settings) }
                    guard let file = self.file else { return }
                    for block in blocks {
                        guard block.start == self.start + file.framePosition,
                              block.pcm.format.isEqual(self.format) else { self.failed = true; return }
                        try file.write(from: block.pcm)
                    }
                } catch { self.failed = true }
            }
        }

        func finish(_ end: PlayerAnchor) -> SourceSoundtrack? {
            guard accepting else { return nil }
            return queue.sync {
                defer { file = nil }
                guard !failed, let length = file?.length, length > 0 else { return nil }
                return SourceSoundtrack(file: destination, first: anchor, last: end, stableFrom: stableFrom,
                                        firstFrame: start, frameCount: length, sampleRate: format.sampleRate)
            }
        }
    }
}
