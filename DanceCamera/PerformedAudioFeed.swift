import AVFoundation
import AudioToolbox
import Synchronization

struct SoundtrackTake {
    let url: URL
    /// Presentation of the first CAF frame, in CMClock host-clock seconds.
    let speedChanges: [SpeedChange]
    let firstAudioHostTime: TimeInterval
    let mixerEdits: MixerEdits
    var source: SourceSoundtrack?
    var sourceFallback = SourceFallback.noAnchor
}

// Mix songs to a stable program format before the hardware mixer adapts to the route.
// A unity-gain unit exposes its actual post-render PCM. The speaker and the feed
// therefore share one time-pitch render, even when a song is mono or changes rate.
final class PerformedAudioBus {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let mixer = AVAudioMixerNode()
    let output = AVAudioUnitEQ(numberOfBands: 1)

    func attach(to engine: AVAudioEngine) {
        output.bands[0].bypass = true
        engine.attach(mixer)
        engine.attach(output)
        engine.connect(mixer, to: output, format: Self.format)
        engine.connect(output, to: engine.mainMixerNode, format: Self.format)
    }
}

// Single render-thread producer, single serial-queue consumer. The render callback
// copies into preallocated planes and never allocates, waits on disk or calls a sink.
private final class RenderRing {
    final class Slot {
        let pcm: AVAudioPCMBuffer
        let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
        var start: Int64 = 0, sample = 0.0
        var host: UInt64 = 0, arrival: UInt64 = 0
        var frames = 0
        init(capacity: UInt32) {
            pcm = AVAudioPCMBuffer(pcmFormat: PerformedAudioBus.format, frameCapacity: capacity)!
            left = pcm.floatChannelData![0]; right = pcm.floatChannelData![1]
        }
    }
    let slots: [Slot]
    let capacity: UInt32
    let read = Atomic<Int>(0), write = Atomic<Int>(0), completedFrames = Atomic<Int64>(0)
    private var framesRendered: Int64 = 0

    init(capacity: UInt32) {
        self.capacity = capacity
        slots = (0..<64).map { _ in Slot(capacity: capacity) }
    }

    func receive(_ flags: AudioUnitRenderActionFlags, _ time: AudioTimeStamp, _ count: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) {
        guard flags.contains(.unitRenderAction_PostRender), count > 0 else { return }
        let start = framesRendered
        framesRendered += Int64(count)
        defer { completedFrames.store(framesRendered, ordering: .releasing) }
        let index = write.load(ordering: .relaxed)
        guard !flags.contains(.unitRenderAction_PostRenderError), count <= capacity,
              index - read.load(ordering: .acquiring) < slots.count else {
            return
        }
        let slot = slots[index % slots.count], bytes = Int(count) * MemoryLayout<Float>.size
        if flags.contains(.unitRenderAction_OutputIsSilence) {
            memset(slot.left, 0, bytes); memset(slot.right, 0, bytes)
        } else {
            guard let data else { return }
            let planes = UnsafeMutableAudioBufferListPointer(data)
            guard planes.count == 2, Int(planes[0].mDataByteSize) >= bytes, Int(planes[1].mDataByteSize) >= bytes,
                  let left = planes[0].mData, let right = planes[1].mData else {
                return
            }
            memcpy(slot.left, left, bytes); memcpy(slot.right, right, bytes)
        }
        slot.arrival = mach_absolute_time()
        slot.host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : 0
        slot.sample = time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : .nan
        slot.start = start; slot.frames = Int(count)
        write.store(index + 1, ordering: .releasing)
    }
}

private let captureRender: AURenderCallback = { context, flags, time, bus, frames, data in
    if bus == 0 {
        Unmanaged<RenderRing>.fromOpaque(context).takeUnretainedValue().receive(flags.pointee, time.pointee, frames, data)
    }
    return noErr
}

// The render call's frame count owns continuity. A mid-epoch hardware stall needs
// independent agreement from the unit's sample and host clocks AND real callback
// elapsed time. A missing slot is independently known from the render frame counter.
struct PerformedClock {
    private var anchor: Double?
    private var previous: (end: Int64, sampleEnd: Double, hostEnd: Double?, arrivalEnd: Double)?
    mutating func position(start: Int64, frames: Int, sample: Double, host: Double?, arrival: Double, latency: Double,
                           earliest: Double?) -> Double {
        let hz = PerformedAudioBus.format.sampleRate, duration = Double(frames) / hz
        if anchor == nil { anchor = max((host ?? arrival) + latency, earliest ?? -.infinity) - Double(start) / hz }
        if let previous, let host, let priorHost = previous.hostEnd, sample.isFinite, previous.sampleEnd.isFinite {
            let missing = Double(start - previous.end) / hz
            let sampleGap = (sample - previous.sampleEnd) / hz - missing
            let hostGap = host - priorHost - missing
            let elapsedGap = arrival - previous.arrivalEnd - missing
            if sampleGap > 1 / hz, abs(hostGap - sampleGap) <= 2 / hz,
               elapsedGap >= 0.75 * sampleGap, abs(elapsedGap - sampleGap) <= max(0.001, sampleGap * 0.25) {
                anchor! += sampleGap
            }
        }
        previous = (start + Int64(frames), sample + Double(frames), host.map { $0 + duration }, arrival + duration)
        return anchor! + Double(start) / hz
    }
}

struct PerformedAudioBlock {
    let pcm: AVAudioPCMBuffer
    let host: Double

    func sampleBuffer() throws -> CMSampleBuffer {
        let pts = CMTime(seconds: host, preferredTimescale: 1_000_000_000)
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
            sampleCount: Int(pcm.frameLength), presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                  flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(sample) == noErr else { throw TakeError("Could not package performed audio.") }
        return sample
    }
}

enum PerformedAudioEvent {
    case samples(CMSampleBuffer)
    case discontinuity(CMTimeRange)
}

final class PerformedAudioFeed: @unchecked Sendable {
    private let writer = DispatchQueue(label: "DanceCamera.soundtrack.write")
    private var history: [PerformedAudioBlock] = []
    private var clock = PerformedClock()
    private var lastEnd: Double?
    private var ring: RenderRing?
    private var observer: AudioUnit?
    private var timer: DispatchSourceTimer?
    private var frameEnd: Int64 = 0
    private var subscriber: (id: UUID, output: AsyncThrowingStream<PerformedAudioEvent, Error>.Continuation)?
    private var speedHistory: [SpeedChange] = []
    private var recordedSpeeds: [SpeedChange] = []

    func speed(_ rate: Double, host: Double) {
        writer.async {
            guard self.speedHistory.last?.rate != rate else { return }
            let event = SpeedChange(host: host, rate: rate)
            self.speedHistory.append(event)
            // Keep one event preceding the pre-roll window.
            while self.speedHistory.count > 1 && self.speedHistory[1].host < host - 3 { self.speedHistory.removeFirst() }
            if self.takeOpen { self.recordedSpeeds.append(event) }
        }
    }
    private var latency = 0.0
    private var takeOpen = false
    private var recording: MixerRecording?
    private var destination: URL?
    private var writeError: Error?

    func install(on output: AVAudioUnitEQ, drainInterval: DispatchTimeInterval = .milliseconds(5)) throws {
        let format = output.outputFormat(forBus: 0)
        guard observer == nil, format.sampleRate == PerformedAudioBus.format.sampleRate, format.channelCount == 2,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw TakeError("The performed-audio bus has an unsupported format.")
        }
        let capacity = max(4096, output.auAudioUnit.maximumFramesToRender)
        guard capacity <= 32768 else { throw TakeError("The audio render buffer is too large.") }
        let ring = RenderRing(capacity: capacity)
        let result = AudioUnitAddRenderNotify(output.audioUnit, captureRender, Unmanaged.passUnretained(ring).toOpaque())
        guard result == noErr else { throw TakeError("Could not capture the live audio render (\(result)).") }
        writer.sync {
            self.ring = ring; observer = output.audioUnit; clock = PerformedClock(); frameEnd = 0
            let timer = DispatchSource.makeTimerSource(queue: writer)
            timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer
            timer.resume()
        }
    }

    func setLatency(_ value: Double) {
        writer.sync {
            let delay = value.isFinite ? max(0, value) : 0
            guard abs(delay - latency) > 1 / PerformedAudioBus.format.sampleRate else { return }
            drain()
            latency = delay
            clock = PerformedClock()
        }
    }

    // Streams owned Core Media samples as they are rendered, independently of the
    // file writer. A slow consumer gets an explicit discontinuity rather than
    // blocking the speaker or silently skipping audio. One consumer at a time.
    func samples() -> AsyncThrowingStream<PerformedAudioEvent, Error> {
        let (stream, output) = AsyncThrowingStream<PerformedAudioEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let id = UUID()
        output.onTermination = { [weak self] _ in
            self?.writer.async { [weak self] in
                if self?.subscriber?.id == id { self?.subscriber = nil }
            }
        }
        writer.sync {
            subscriber?.output.finish()
            subscriber = (id, output)
        }
        return stream
    }

    func flush() { writer.sync { drain() } }

    private func drain(finishing: Bool = false) {
        guard let ring else { return }
        let completed = ring.completedFrames.load(ordering: .acquiring)
        let limit = ring.write.load(ordering: .acquiring)
        var index = ring.read.load(ordering: .relaxed)
        while index < limit {
            let slot = ring.slots[index % ring.slots.count]
            slot.pcm.frameLength = UInt32(slot.frames)
            let host = clock.position(start: slot.start, frames: slot.frames, sample: slot.sample,
                                      host: slot.host == 0 ? nil : AVAudioTime.seconds(forHostTime: slot.host),
                                      arrival: AVAudioTime.seconds(forHostTime: slot.arrival), latency: latency, earliest: lastEnd)
            let copy = slot.pcm.mixerCopy()
            let end = slot.start + Int64(slot.frames)
            index += 1
            ring.read.store(index, ordering: .releasing)
            guard let copy else { continue }
            let block = PerformedAudioBlock(pcm: copy, host: host)
            if let lastEnd, host - lastEnd > 1.5 / copy.format.sampleRate { sendGap(from: lastEnd, to: host) }
            frameEnd = end
            lastEnd = host + Double(copy.frameLength) / copy.format.sampleRate
            history.append(block)
            while let first = history.first, host - first.host > 2 { history.removeFirst() }
            if let subscriber {
                do {
                    send(.samples(try block.sampleBuffer()))
                } catch { subscriber.output.finish(throwing: error); self.subscriber = nil }
            }
            if takeOpen { append(block) }
        }
        if finishing, completed > frameEnd, let lastEnd, frameEnd > 0 {
            let end = lastEnd + Double(completed - frameEnd) / PerformedAudioBus.format.sampleRate
            sendGap(from: lastEnd, to: end)
            if takeOpen {
                do { try recording?.completeGap(until: end) } catch { writeError = error }
            }
            self.lastEnd = end; frameEnd = completed
        }
    }

    private func sendGap(from start: Double, to end: Double) {
        send(.discontinuity(CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
                                        end: CMTime(seconds: end, preferredTimescale: 1_000_000_000))))
    }

    private func send(_ event: PerformedAudioEvent) {
        guard let subscriber else { return }
        if case .dropped = subscriber.output.yield(event) {
            subscriber.output.finish(throwing: TakeError("The live audio consumer fell behind. Reconnect at the next timestamp."))
            self.subscriber = nil
        }
    }

    // Stop the engine before disconnecting this observer; no render callback
    // may still be referencing its ring when the program graph is retired.
    func uninstall() {
        writer.sync {
            if let observer, let ring {
                AudioUnitRemoveRenderNotify(observer, captureRender, Unmanaged.passUnretained(ring).toOpaque())
            }
            timer?.cancel(); timer = nil
            drain(finishing: true); observer = nil; ring = nil
            history.removeAll()
        }
    }

    func shutdown() {
        uninstall()
        writer.sync { subscriber?.output.finish(); subscriber = nil }
    }

    func begin() throws {
        try writer.sync {
            guard !takeOpen else { throw TakeError("A soundtrack is already being recorded.") }
            drain()
            takeOpen = true
            recordedSpeeds = speedHistory
            writeError = nil
            for block in history { append(block) }
            if let error = writeError { clear(removing: true); throw error }
        }
    }

    func discard() { writer.sync { clear(removing: true) } }

    func finish() throws -> SoundtrackTake? {
        try writer.sync {
            drain(finishing: true)
            if let error = writeError { clear(removing: true); throw error }
            let result: SoundtrackTake?
            if let url = destination, let recording, recording.file.length > 0 {
                result = SoundtrackTake(url: url, speedChanges: recordedSpeeds, firstAudioHostTime: recording.origin,
                                       mixerEdits: recording.edits)
            } else { result = nil }
            clear(removing: result == nil)
            return result
        }
    }

    private func clear(removing: Bool) {
        recording = nil // close and finalize the CAF header before the exporter opens it
        if removing, let destination { try? FileManager.default.removeItem(at: destination) }
        destination = nil
        writeError = nil
        takeOpen = false
        recordedSpeeds = []
    }

    private func append(_ block: PerformedAudioBlock) {
        guard writeError == nil else { return }
        do {
            if recording == nil {
                let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
                destination = url
                recording = try MixerRecording(url: url, format: block.pcm.format, origin: block.host)
            }
            try recording?.append(block.pcm, host: block.host)
        } catch { writeError = error }
    }
}
