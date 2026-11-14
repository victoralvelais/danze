import AVFoundation
import AudioToolbox
import Combine
import Foundation

struct SoundtrackTake {
    let url: URL
    /// Presentation of the first CAF frame, in CMClock host-clock seconds.
    let firstAudioHostTime: TimeInterval
}

@MainActor
final class StreamingSoundtrack: ObservableObject {
    enum State: Equatable { case idle, buffering, playing, paused, ended, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    private let player = SoundtrackPlayer()
    private var generation = UUID()

    func play(_ url: URL, title: String) { start(.file(url), title: title) }
    func play(_ request: URLRequest, title: String) { start(.network(request), title: title) }

    private func start(_ source: MusicSource, title: String) {
        let id = UUID()
        generation = id
        self.title = title
        state = .buffering
        player.play(source) { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                self.state = state
            }
        }
    }

    func stop() {
        generation = UUID()
        player.stop()
        state = .idle
    }

    func pause() { player.pause() }
    func resume() { player.resume() }
    func beginTake() throws { try player.beginTake() }

    func finishTake() async throws -> SoundtrackTake? { try await player.finishTake() }
    func discardTake() { player.discardTake() }
}

private enum MusicSource { case file(URL), network(URLRequest) }

// A dedicated serial queue owns the parser, converter, playback graph, and network task.
// Packet/tap callbacks never modify SwiftUI state or touch camera capture queues.
private final class SoundtrackPlayer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias State = StreamingSoundtrack.State
    private let queue = DispatchQueue(label: "DanceCamera.soundtrack")
    private let graph = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let tap = MusicTap()
    private var callback: ((State) -> Void)?
    private var lastState: State?
    private var playbackID = UUID()
    private var session: URLSession?
    private var network: URLSessionDataTask?
    private var suspended = false
    private var eof = false
    private var configured = false
    private var running = false
    private var paused = false
    private var pendingFrames: Int64 = 0
    private var sampleRate = 0.0
    private var localFile: AVAudioFile?
    private var parser: IncrementalDecoder?
    private var configurationObserver: NSObjectProtocol?

    override init() {
        super.init()
        graph.attach(node)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if self.configured && !self.graph.isRunning {
                    self.fail(TakeError("Audio output changed. Select Play to use the new route."))
                }
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func play(_ source: MusicSource, callback: @escaping (State) -> Void) {
        queue.async {
            self.reset()
            self.callback = callback
            self.report(.buffering)
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .default)
                try audio.setActive(true)
                switch source {
                case .file(let url):
                    let file = try AVAudioFile(forReading: url)
                    self.localFile = file
                    try self.configure(file.processingFormat)
                    try self.fillLocal()
                case .network(let request):
                    self.parser = try IncrementalDecoder { [weak self] buffer in
                        guard let self else { return }
                        try self.configure(buffer.format)
                        self.schedule(buffer)
                    }
                    let config = URLSessionConfiguration.ephemeral
                    config.urlCache = nil
                    config.httpShouldSetCookies = false
                    config.urlCredentialStorage = nil
                    let delegates = OperationQueue()
                    delegates.maxConcurrentOperationCount = 1
                    delegates.underlyingQueue = self.queue
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
                    self.session = session
                    let task = session.dataTask(with: request)
                    self.network = task
                    task.resume()
                }
            } catch { self.fail(error) }
        }
    }

    func stop() {
        queue.async {
            self.reset()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func pause() {
        queue.async {
            guard self.lastState == .playing || self.lastState == .buffering else { return }
            self.paused = true
            if self.running { self.node.pause() }
            self.running = false
            if let task = self.network, !self.suspended { task.suspend(); self.suspended = true }
            self.report(.paused)
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            if self.suspended && (self.sampleRate == 0 || Double(self.pendingFrames) < self.sampleRate * 5) {
                self.network?.resume()
                self.suspended = false
            }
            if self.pendingFrames > 0 { self.startNode() } else { self.report(self.eof ? .ended : .buffering) }
        }
    }
    func beginTake() throws { try queue.sync { try tap.begin() } }
    func discardTake() { queue.sync { tap.discard() } }

    func finishTake() async throws -> SoundtrackTake? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.tap.finish()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configure(_ format: AVAudioFormat) throws {
        guard !configured else { return }
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TakeError("No playable audio format.") }
        graph.connect(node, to: graph.mainMixerNode, format: format)
        let mixed = graph.mainMixerNode.outputFormat(forBus: 0)
        guard mixed.channelCount > 0, mixed.sampleRate > 0 else { throw TakeError("No audio output is available.") }
        try tap.install(on: graph.mainMixerNode, format: mixed)
        graph.prepare()
        try graph.start()
        sampleRate = format.sampleRate
        // Use one downstream latency estimate; adding hardware and session latencies would count the route twice.
        tap.setLatency(max(graph.mainMixerNode.outputPresentationLatency, graph.outputNode.presentationLatency,
                           AVAudioSession.sharedInstance().outputLatency))
        configured = true
    }

    private func report(_ state: State) {
        guard lastState != state else { return }
        lastState = state
        callback?(state)
    }

    private func reset() {
        playbackID = UUID()
        network?.cancel()
        session?.invalidateAndCancel()
        network = nil
        session = nil
        parser = nil
        localFile = nil
        node.stop()
        graph.stop()
        tap.uninstall(from: graph.mainMixerNode)
        graph.disconnectNodeOutput(node)
        eof = false
        configured = false
        running = false
        suspended = false
        paused = false
        pendingFrames = 0
        sampleRate = 0
        lastState = nil
    }

    private func fail(_ error: Error) {
        reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        report(.failed(error.localizedDescription))
    }

    private func fillLocal() throws {
        guard let file = localFile else { return }
        while !eof && Double(pendingFrames) < 3 * sampleRate {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
                throw TakeError("Could not allocate playback audio.")
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { reachedEOF(); return }
            schedule(buffer)
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let id = playbackID
        let count = Int64(buffer.frameLength)
        pendingFrames += count
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.playbackID == id else { return }
                self.pendingFrames -= count
                if !self.paused && self.suspended && Double(self.pendingFrames) < self.sampleRate * 2 {
                    self.network?.resume()
                    self.suspended = false
                }
                do { try self.fillLocal() } catch { self.fail(error); return }
                if self.pendingFrames == 0 && !self.paused {
                    if self.eof { self.report(.ended) }
                    else { self.report(.buffering) }
                }
            }
        }
        if Double(pendingFrames) >= sampleRate * 0.35 || running { startNode() }
        if let network, !suspended, Double(pendingFrames) >= sampleRate * 5 {
            network.suspend()
            suspended = true
        }
    }

    private func startNode() {
        guard pendingFrames > 0 && !paused else { return }
        if !running { node.play(); running = true }
        report(.playing)
    }

    private func reachedEOF() {
        guard configured else { fail(TakeError("The selected stream contained no playable audio.")); return }
        eof = true
        if !paused {
            if pendingFrames > 0 { startNode() } else { report(.ended) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === network else { completionHandler(.cancel); return }
        let mime = response.mimeType?.lowercased() ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !mime.hasPrefix("text/"), !mime.contains("xml"), !mime.contains("json") else {
            completionHandler(.cancel)
            fail(TakeError("Navidrome did not return audio. Check access to this song and the server address."))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === network else { return }
        do { try parser?.append(data) } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === network else { return }
        network = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if let error { fail(error); return }
        do { try parser?.finish(); parser = nil; reachedEOF() }
        catch { fail(error) }
    }
}


// Parse and decode only bytes the URLSession delegate has actually received.
// Native codec state survives arbitrary network packet boundaries and starvation.
private final class IncrementalDecoder {
    private let output: (AVAudioPCMBuffer) throws -> Void
    private var stream: AudioFileStreamID?
    private var conversion: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var problem: Error?

    init(output: @escaping (AVAudioPCMBuffer) throws -> Void) throws {
        self.output = output
        let code = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { owner, id, property, _ in
            guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
            let decoder = Unmanaged<IncrementalDecoder>.fromOpaque(owner).takeUnretainedValue()
            do { try decoder.configure(id) } catch { decoder.problem = error }
        }, { owner, bytes, packets, data, descriptions in
            let decoder = Unmanaged<IncrementalDecoder>.fromOpaque(owner).takeUnretainedValue()
            guard decoder.problem == nil else { return }
            do { try decoder.decode(bytes: Int(bytes), packets: Int(packets), data: data, descriptions: descriptions) }
            catch { decoder.problem = error }
        }, 0, &stream)
        guard code == noErr else { throw TakeError("Could not open the audio stream parser (\(code)).") }
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    func append(_ data: Data) throws {
        guard let stream, !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = min(16384, raw.count - offset)
                let status = AudioFileStreamParseBytes(stream, UInt32(count), base.advanced(by: offset), [])
                if let problem { throw problem }
                guard status == noErr else { throw TakeError("The server returned an unsupported audio stream (\(status)).") }
                offset += count
            }
        }
    }

    private func configure(_ id: AudioFileStreamID) throws {
        guard conversion == nil else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: description))
        guard AudioFileStreamGetProperty(id, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              description.mSampleRate > 0, (1...8).contains(description.mChannelsPerFrame),
              let source = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: source.channelCount),
              let converter = AVAudioConverter(from: source, to: pcm) else {
            throw TakeError("Cannot decode this audio format. Enable MP3 transcoding in Navidrome.")
        }
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0, cookieSize <= 1024 * 1024 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw in
                AudioFileStreamGetProperty(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, raw.baseAddress!)
            }
            if status == noErr { converter.magicCookie = cookie }
        }
        inputFormat = source
        outputFormat = pcm
        conversion = converter
    }

    private func decode(bytes: Int, packets: Int, data: UnsafeRawPointer,
                        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) throws {
        guard packets > 0, bytes > 0 else { return }
        guard let inputFormat, let conversion, let outputFormat else { throw TakeError("No audio format from stream.") }
        let fixed = Int(inputFormat.streamDescription.pointee.mBytesPerPacket)
        guard descriptions != nil || (fixed > 0 && packets <= bytes / fixed) else {
            throw TakeError("Missing stream packet boundaries.")
        }
        var index = 0
        var invalid = false
        let input: AVAudioConverterInputBlock = { wanted, status in
            guard index < packets, wanted > 0 else { status.pointee = .noDataNow; return nil }
            let count = min(Int(wanted), min(32, packets - index))
            var maximum = 0
            for i in index..<(index + count) {
                let start = descriptions.map { Int($0[i].mStartOffset) } ?? i * fixed
                let size = descriptions.map { Int($0[i].mDataByteSize) } ?? fixed
                guard size > 0, size <= bytes, start >= 0, start <= bytes - size else {
                    invalid = true; status.pointee = .noDataNow; return nil
                }
                maximum = max(maximum, size)
            }
            let compressed: AVAudioCompressedBuffer
            if fixed > 0 {
                guard maximum <= fixed else { invalid = true; status.pointee = .noDataNow; return nil }
                compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: UInt32(count))
            } else {
                compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: UInt32(count), maximumPacketSize: maximum)
            }
            var offset = 0
            for n in 0..<count {
                let i = index + n
                let size = descriptions.map { Int($0[i].mDataByteSize) } ?? fixed
                let start = descriptions.map { Int($0[i].mStartOffset) } ?? i * fixed
                compressed.data.advanced(by: offset).copyMemory(from: data.advanced(by: start), byteCount: size)
                compressed.packetDescriptions?[n] = AudioStreamPacketDescription(
                    mStartOffset: Int64(offset), mVariableFramesInPacket: descriptions?[i].mVariableFramesInPacket ?? 0,
                    mDataByteSize: UInt32(size))
                offset += size
            }
            compressed.packetCount = UInt32(count)
            compressed.byteLength = UInt32(offset)
            index += count
            status.pointee = .haveData
            return compressed
        }
        try convert(conversion, format: outputFormat, input: input)
        guard !invalid, index == packets else { throw TakeError("Corrupt or incomplete audio packets.") }
    }

    func finish() throws {
        if let conversion, let outputFormat {
            try convert(conversion, format: outputFormat) { _, status in status.pointee = .endOfStream; return nil }
        }
    }

    private func convert(_ converter: AVAudioConverter, format: AVAudioFormat, input: AVAudioConverterInputBlock) throws {
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw TakeError("Could not allocate decoder output.") }
            var error: NSError?
            let result = converter.convert(to: pcm, error: &error, withInputFrom: input)
            if result == .error { throw error ?? TakeError("Failed to decode the streamed audio.") }
            if pcm.frameLength > 0 { try output(pcm) }
            if result != .haveData || pcm.frameLength == 0 { return }
        }
    }
}


// The mixer runs even when the network starves or the player node pauses. Its tap
// therefore contains the same gaps as the speaker output. Keep two seconds of
// render history to include audio already en route to a Bluetooth device.
private final class MusicTap {
    private struct Block {
        let pcm: AVAudioPCMBuffer
        let host: Double
    }
    private let writer = DispatchQueue(label: "DanceCamera.soundtrack.write")
    private let backlog = DispatchSemaphore(value: 48)
    private var history: [Block] = []
    private var epoch = UUID()
    private var installed = false
    private var latency = 0.0
    private var takeOpen = false
    private var file: AVAudioFile?
    private var destination: URL?
    private var origin: Double?
    private var writeError: Error?

    func install(on mixer: AVAudioMixerNode, format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw TakeError("The audio mixer has an unsupported output format.")
        }
        let id = UUID()
        writer.sync { epoch = id; history.removeAll(); latency = 0 }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self, time.isHostTimeValid, buffer.frameLength > 0 else { return }
            guard self.backlog.wait(timeout: .now()) == .success else {
                // Do not block the render thread or create an unbounded queue. If
                // disk I/O fell behind, fail this take instead of inventing audio.
                self.writer.async {
                    if self.epoch == id && self.takeOpen {
                        self.writeError = TakeError("The iPhone could not write the soundtrack fast enough.")
                    }
                }
                return
            }
            guard let copy = Self.copy(buffer, from: 0) else { self.backlog.signal(); return }
            let timestamp = AVAudioTime.seconds(forHostTime: time.hostTime)
            self.writer.async {
                defer { self.backlog.signal() }
                guard self.epoch == id else { return }
                let block = Block(pcm: copy, host: timestamp + self.latency)
                self.history.append(block)
                while let first = self.history.first, block.host - first.host > 2 {
                    self.history.removeFirst()
                }
                if self.takeOpen { self.append(block) }
            }
        }
        installed = true
    }

    func setLatency(_ value: Double) { writer.sync { latency = value.isFinite ? max(0, value) : 0 } }

    func uninstall(from mixer: AVAudioMixerNode) {
        guard installed else { return }
        mixer.removeTap(onBus: 0)
        installed = false
        writer.sync { epoch = UUID(); history.removeAll() }
    }

    func begin() throws {
        try writer.sync {
            guard !takeOpen else { throw TakeError("A soundtrack is already being recorded.") }
            takeOpen = true
            writeError = nil
            for block in history { append(block) }
            if let error = writeError { clear(removing: true); throw error }
        }
    }

    func discard() { writer.sync { clear(removing: true) } }

    func finish() throws -> SoundtrackTake? {
        try writer.sync {
            if let error = writeError { clear(removing: true); throw error }
            let result: SoundtrackTake?
            if let url = destination, let host = origin, let file, file.length > 0 {
                result = SoundtrackTake(url: url, firstAudioHostTime: host)
            } else { result = nil }
            clear(removing: result == nil)
            return result
        }
    }

    private func clear(removing: Bool) {
        file = nil // close and finalize the CAF header before the exporter opens it
        if removing, let destination { try? FileManager.default.removeItem(at: destination) }
        destination = nil
        origin = nil
        writeError = nil
        takeOpen = false
    }

    private func append(_ block: Block) {
        guard writeError == nil else { return }
        do {
            if file == nil {
                let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
                destination = url
                file = try AVAudioFile(forWriting: url, settings: block.pcm.format.settings)
                origin = block.host
            }
            guard let file, let origin else { return }
            let format = file.processingFormat
            guard format.sampleRate == block.pcm.format.sampleRate, format.channelCount == block.pcm.format.channelCount else {
                throw TakeError("Audio output format changed during the take.")
            }
            let offset = (block.host - origin) * format.sampleRate
            guard offset.isFinite, abs(offset) < 86400 * format.sampleRate else { throw TakeError("The audio clock changed unexpectedly.") }
            var difference = Int64(offset.rounded()) - file.framePosition
            // Ignore tiny timestamp-to-sample rounding jitter. At a genuine
            // discontinuity, insert silence or skip duplicated leading samples.
            if abs(difference) <= 1 { difference = 0 }
            if difference > 0 {
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                      let channels = silence.floatChannelData else { throw TakeError("Could not align the audio gap.") }
                for i in 0..<Int(format.channelCount) {
                    memset(channels[i], 0, 4096 * MemoryLayout<Float>.size)
                }
                while difference > 0 {
                    silence.frameLength = UInt32(min(4096, difference))
                    try file.write(from: silence)
                    difference -= Int64(silence.frameLength)
                }
            }
            if difference >= 0 { try file.write(from: block.pcm) }
            else if -difference < Int64(block.pcm.frameLength), let tail = Self.copy(block.pcm, from: Int(-difference)) {
                try file.write(from: tail)
            }
        } catch { writeError = error }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let count = Int(buffer.frameLength) - start
        guard count > 0, let input = buffer.floatChannelData,
              let pcm = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: UInt32(count)),
              let output = pcm.floatChannelData else { return nil }
        pcm.frameLength = UInt32(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            output[channel].update(from: input[channel].advanced(by: start), count: count)
        }
        return pcm
    }
}
