import AVFoundation
import Combine
import Foundation

struct SoundtrackTake {
    let url: URL
    /// Presentation of the first CAF frame, in CMClock host-clock seconds.
    let speedChanges: [SpeedChange]
    let firstAudioHostTime: TimeInterval
    let mixerEdits: MixerEdits
    var source: SourceSoundtrack?
    var sourceFallback = SourceFallback.noAnchor
}

@MainActor
final class StreamingSoundtrack: ObservableObject {
    enum State: Equatable { case idle, buffering, playing, paused, ended, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    private let player = SoundtrackPlayer()
    private var generation = UUID()

    func play(_ url: URL, title: String) { start(.file(url), title: title) }
    func playLibrary(_ url: URL, title: String) { start(.library(url), title: title) }
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

    func setRate(_ value: Double) { player.setRate(value) }
    func pause() { player.pause() }
    func resume() { player.resume() }
    func beginTake() throws { try player.beginTake() }

    func finishTake() async throws -> SoundtrackTake? { try await player.finishTake() }
    func discardTake() { player.discardTake() }
}

private enum MusicSource { case file(URL), network(URLRequest), library(URL) }

// A dedicated serial queue owns the parser, converter, playback graph, and network task.
// Packet/tap callbacks never modify SwiftUI state or touch camera capture queues.
private final class SoundtrackPlayer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias State = StreamingSoundtrack.State
    private let queue = DispatchQueue(label: "DanceCamera.soundtrack")
    private let graph = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let tap = MusicTap()
    private let sourceAudio = SourceAudioCapture()
    private var stableFrom = Double.infinity
    private var sourceClockReliable = true
    private let pitch = AVAudioUnitTimePitch()
    private var rate = 1.0
    private var outputDelay = 0.0
    private var nextBuffer: AVAudioPCMBuffer?
    private var finishingTail = false
    private var bufferedSeconds: Double { Double(pendingFrames) / (max(1, sampleRate) * rate) }
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
    private var libraryReader: LibraryPCMReader?
    private var configurationObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    override init() {
        super.init()
        graph.attach(node)
        graph.attach(pitch)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.sourceAudio.cancel()
                if self.configured && !self.graph.isRunning {
                    self.fail(TakeError("Audio output changed. Select Play to use the new route."))
                }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.sourceAudio.cancel()
                if self.running { self.markSpeed(self.rate) }
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    func setRate(_ value: Double) {
        queue.async {
            let tuned = min(2, max(0.5, value))
            guard self.rate != tuned else { return }
            self.sourceAudio.cancel()
            self.rate = tuned
            self.pitch.rate = Float(self.rate)
            if self.running { self.markSpeed(self.rate) }
            if !self.paused && self.suspended && self.bufferedSeconds < 2 { self.network?.resume(); self.suspended = false }
        }
    }

    private func markSpeed(_ value: Double) {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        stableFrom = now + presentationDelay
        tap.speed(value, host: now + outputDelay + pitch.latency)
    }

    private var presentationDelay: Double {
        // The player's downstream total can already include the pitch unit and
        // route. Only use the known component sum as a lower bound.
        let routeDelay = max(graph.mainMixerNode.outputPresentationLatency, graph.outputNode.presentationLatency,
                             AVAudioSession.sharedInstance().outputLatency)
        return max(node.outputPresentationLatency, routeDelay + pitch.latency)
    }

    private func sourceAnchor() -> PlayerAnchor? {
        guard sourceClockReliable, running, !paused, graph.isRunning, node.isPlaying, let render = node.lastRenderTime,
              render.isHostTimeValid, render.isSampleTimeValid, let player = node.playerTime(forNodeTime: render),
              player.isSampleTimeValid, player.sampleTime >= 0, player.sampleRate > 0 else { return nil }
        let host = AVAudioTime.seconds(forHostTime: render.hostTime)
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guard abs(now - host) < 0.5 else { return nil }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid)
        guard !route.isEmpty else { return nil }
        return PlayerAnchor(host: host + presentationDelay, song: Double(player.sampleTime) / player.sampleRate,
                            rate: rate, route: route)
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
                case .library(let url):
                    self.libraryReader = try LibraryPCMReader(url)
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
            self.sourceAudio.cancel()
            self.paused = true
            if self.running { self.node.pause(); self.markSpeed(1) }
            self.running = false
            if let task = self.network, !self.suspended { task.suspend(); self.suspended = true }
            self.report(.paused)
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            if self.suspended && (self.bufferedSeconds < 5) {
                self.network?.resume()
                self.suspended = false
            }
            if self.eof || self.bufferedSeconds >= 0.85 { self.startNode() } else { self.report(.buffering) }
        }
    }
    func beginTake() throws {
        try queue.sync {
            try tap.begin()
            sourceAudio.begin(sourceAnchor(), stableFrom: stableFrom)
        }
    }

    func discardTake() { queue.sync { sourceAudio.cancel(); tap.discard() } }

    func finishTake() async throws -> SoundtrackTake? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let source = self.sourceAudio.finish(self.sourceAnchor())
                do {
                    var take = try self.tap.finish()
                    take?.source = source
                    take?.sourceFallback = self.sourceAudio.fallback
                    continuation.resume(returning: take)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configure(_ format: AVAudioFormat) throws {
        guard !configured else { return }
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TakeError("No playable audio format.") }
        connectMusicPlayer(node, through: pitch, to: graph, format: format, rate: rate)
        let mixed = graph.mainMixerNode.outputFormat(forBus: 0)
        guard mixed.channelCount > 0, mixed.sampleRate > 0 else { throw TakeError("No audio output is available.") }
        try tap.install(on: graph.mainMixerNode, format: mixed)
        graph.prepare()
        outputDelay = max(graph.mainMixerNode.outputPresentationLatency, graph.outputNode.presentationLatency,
                          AVAudioSession.sharedInstance().outputLatency)
        tap.setLatency(outputDelay)
        try graph.start()
        sampleRate = format.sampleRate
        configured = true
    }

    private func report(_ state: State) {
        guard lastState != state else { return }
        lastState = state
        callback?(state)
    }

    private func reset() {
        if running { markSpeed(1) }
        sourceAudio.reset()
        stableFrom = .infinity
        sourceClockReliable = true
        playbackID = UUID()
        nextBuffer = nil
        finishingTail = false
        network?.cancel()
        session?.invalidateAndCancel()
        network = nil
        session = nil
        parser = nil
        localFile = nil
        libraryReader = nil
        node.stop()
        graph.stop()
        tap.uninstall(from: graph.mainMixerNode)
        graph.disconnectNodeOutput(node)
        graph.disconnectNodeOutput(pitch)
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
        if let libraryReader {
            while !eof && bufferedSeconds < 3 {
                guard let pcm = try libraryReader.read() else { reachedEOF(); return }
                try configure(pcm.format)
                schedule(pcm)
            }
            return
        }
        guard let file = localFile else { return }
        while !eof && bufferedSeconds < 3 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
                throw TakeError("Could not allocate playback audio.")
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { reachedEOF(); return }
            schedule(buffer)
        }
    }

    // Keep one buffer in hand so only the real last buffer waits for hardware playback.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        sourceAudio.append(buffer)
        if let previous = nextBuffer { enqueue(previous, last: false) }
        nextBuffer = buffer
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, last: Bool) {
        let id = playbackID
        let count = Int64(buffer.frameLength)
        pendingFrames += count
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: last ? .dataPlayedBack : .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.playbackID == id else { return }
                self.pendingFrames -= count
                self.sourceAudio.didRender(count)
                if !self.paused && self.suspended && self.bufferedSeconds < 2 {
                    self.network?.resume()
                    self.suspended = false
                }
                do { try self.fillLocal() } catch { self.fail(error); return }
                if last {
                    self.sourceAudio.cancel()
                    self.running = false
                    self.tap.speed(1, host: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
                    self.report(.ended)
                } else if self.pendingFrames == 0 && !self.paused && !self.finishingTail {
                    // After a real underrun, the node clock may have advanced
                    // through silence before this completion reached our queue.
                    self.sourceClockReliable = false
                    self.sourceAudio.cancel()
                    self.node.pause()
                    self.running = false
                    self.markSpeed(1)
                    self.report(.buffering)
                }
            }
        }
        if bufferedSeconds >= 0.85 || finishingTail { startNode() }
        if let network, !suspended, bufferedSeconds >= 5 {
            network.suspend()
            suspended = true
        }
    }

    private func startNode() {
        guard pendingFrames > 0, !paused else { return }
        if !running {
            node.play()
            running = true
            markSpeed(rate)
        }
        report(.playing)
    }

    private func reachedEOF() {
        guard configured, let tail = nextBuffer else { fail(TakeError("The selected stream contained no playable audio.")); return }
        eof = true
        finishingTail = true
        nextBuffer = nil
        enqueue(tail, last: true)
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

// The mixer runs even when the network starves or the player node pauses. Its tap
// therefore contains the same gaps as the speaker output. Keep two seconds of
// render history to include audio already en route to a Bluetooth device.
private final class MusicTap {
    private struct Block {
        let pcm: AVAudioPCMBuffer
        let host: Double
        let stampAdjustment: Double
    }
    private let writer = DispatchQueue(label: "DanceCamera.soundtrack.write")
    private let backlog = DispatchSemaphore(value: 48)
    private var history: [Block] = []
    private var epoch = UUID()
    private var timeline = MixerTimeline()
    private var pending: (pcm: AVAudioPCMBuffer, stamp: MixerStamp)?
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
    private var installed = false
    private var latency = 0.0
    private var takeOpen = false
    private var recording: MixerRecording?
    private var destination: URL?
    private var writeError: Error?

    func install(on mixer: AVAudioMixerNode, format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw TakeError("The audio mixer has an unsupported output format.")
        }
        let id = UUID()
        writer.sync { epoch = id; history.removeAll(); timeline = MixerTimeline(); latency = 0 }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self, buffer.frameLength > 0, time.isHostTimeValid || time.isSampleTimeValid else { return }
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
            guard let copy = buffer.mixerCopy() else { self.backlog.signal(); return }
            let timestamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            let sample = time.isSampleTimeValid ? time.sampleTime : nil
            let clockRate = time.isSampleTimeValid ? time.sampleRate : 0
            self.writer.async {
                defer { self.backlog.signal() }
                guard self.epoch == id else { return }
                let stamp = MixerStamp(sample: sample, clockRate: clockRate, host: timestamp.map { $0 + self.latency })
                self.flushPending(followedBy: stamp)
                self.pending = (copy, stamp)
            }
        }
        installed = true
    }

    func setLatency(_ value: Double) { writer.sync { latency = value.isFinite ? max(0, value) : 0 } }

    private func flushPending(followedBy following: MixerStamp? = nil) {
        guard let pending else { return }
        self.pending = nil
        let pcm = pending.pcm
        let prior = history.last?.pcm
        guard let host = timeline.position(pending.stamp, count: Int(pcm.frameLength), pcmRate: pcm.format.sampleRate,
                                           followedBy: following, distinctOverlap: { pcm.differsFromPriorOverlap(prior, frames: $0, roundingFrames: $1) }) else { return }
        let block = Block(pcm: pcm, host: host, stampAdjustment: timeline.stampAdjustment)
        history.append(block)
        while let first = history.first, block.host - first.host > 2 { history.removeFirst() }
        if takeOpen { append(block) }
    }

    func uninstall(from mixer: AVAudioMixerNode) {
        guard installed else { return }
        mixer.removeTap(onBus: 0)
        installed = false
        writer.sync { flushPending(); epoch = UUID(); history.removeAll() }
    }

    func begin() throws {
        try writer.sync {
            guard !takeOpen else { throw TakeError("A soundtrack is already being recorded.") }
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
            flushPending()
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

    private func append(_ block: Block) {
        guard writeError == nil else { return }
        do {
            if recording == nil {
                let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
                destination = url
                recording = try MixerRecording(url: url, format: block.pcm.format, origin: block.host)
            }
            try recording?.append(block.pcm, host: block.host, stampAdjustment: block.stampAdjustment)
        } catch { writeError = error }
    }
}

// Music library URLs can use ipod-library:// and are read through AVAsset.
private final class LibraryPCMReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput

    init(_ url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard !asset.hasProtectedContent, let track = asset.tracks(withMediaType: .audio).first else {
            throw TakeError("This Music item does not expose a recordable audio track.")
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true
        ])
        guard reader.canAdd(output) else { throw TakeError("This Music track cannot be opened.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TakeError("Could not read this Music track.") }
    }

    func read() throws -> AVAudioPCMBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: desc), frameCapacity: UInt32(count))
            else { throw TakeError("Unsupported Music audio format.") }
            pcm.frameLength = UInt32(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                                      into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw TakeError("Could not decode the selected Music track.") }
            return pcm
        }
        guard reader.status == .completed else { throw reader.error ?? TakeError("Reading the Music track was interrupted.") }
        return nil
    }
}
