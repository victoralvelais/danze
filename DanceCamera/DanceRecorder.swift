import SwiftUI
import AVFoundation

enum TakePhase { case idle, starting, recording, saving }

@MainActor
final class DanceRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var message = "Starting camera."
    @Published private(set) var phase = TakePhase.idle
    @Published private(set) var ready = false
    @Published private(set) var quality = ""
    @Published private(set) var takes: [URL] = []
    @Published private(set) var upcoming: [String] = []
    @Published private(set) var outputName = ""
    @Published private(set) var correctionMS: Double = 0
    let session = AVCaptureSession()
    let soundtrack = StreamingSoundtrack()
    private let movie = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let library = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)
    private var routeKey = ""
    private var configuring = false
    private enum Source { case stream(URLRequest, String), file(URL, String) }
    private var current: Source?
    private var next: [(URLRequest, String)] = []
    private var takeURL: URL?
    private var videoStart: Double?
    private var takeCorrection: Double = 0
    private var pendingStop = false

    override init() {
        super.init()
        refreshRoute()
        takes = ((try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mp4", "mov"].contains($0.pathExtension) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func configure() async {
        guard !ready, !configuring else { return }
        configuring = true
        defer { configuring = false }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Allow camera access in Settings to record a take."
            return
        }
        let capture = session, output = movie
        do {
            quality = try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
                sessionQueue.async {
                    do {
                        if capture.inputs.isEmpty {
                            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            else { throw TakeError("No rear camera available.") }
                            let input = try AVCaptureDeviceInput(device: camera)
                            capture.beginConfiguration()
                            defer { capture.commitConfiguration() }
                            capture.automaticallyConfiguresApplicationAudioSession = false
                            guard capture.canAddInput(input) else { throw TakeError("Camera input is unavailable.") }
                            capture.addInput(input)
                            guard capture.canAddOutput(output) else {
                                capture.removeInput(input)
                                throw TakeError("Video output is unavailable.")
                            }
                            capture.addOutput(output)
                            let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
                            if let best = presets.first(where: { capture.canSetSessionPreset($0) }) { capture.sessionPreset = best }
                            if let connection = output.connection(with: .video) {
                                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                                if output.availableVideoCodecTypes.contains(.hevc) {
                                    output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                                }
                            }
                        }
                        capture.startRunning()
                        guard capture.isRunning else { throw TakeError("The camera could not start.") }
                        switch capture.sessionPreset {
                        case .hd4K3840x2160: done.resume(returning: "4K")
                        case .hd1920x1080: done.resume(returning: "1080p")
                        case .hd1280x720: done.resume(returning: "720p")
                        default: done.resume(returning: "Camera")
                        }
                    } catch { done.resume(throwing: error) }
                }
            }
            ready = true
            message = "Camera ready."
        } catch { message = error.localizedDescription }
    }

    func selectFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: local)
        start(.file(local, url.lastPathComponent))
    }

    func selectStream(_ request: URLRequest, title: String, enqueue: Bool) {
        if enqueue, current != nil, [.playing, .buffering, .paused].contains(soundtrack.state) {
            next.append((request, title))
            upcoming.append(title)
        } else { start(.stream(request, title)) }
    }

    private func start(_ source: Source) {
        let previous = current
        current = source
        switch source {
        case let .stream(request, title): soundtrack.play(request, title: title)
        case let .file(url, title): soundtrack.play(url, title: title)
        }
        if case let .file(old, _)? = previous, case let .file(new, _) = source, old == new { return }
        if case let .file(old, _)? = previous { try? FileManager.default.removeItem(at: old) }
    }

    func playNext() {
        guard !next.isEmpty else { return }
        let (request, title) = next.removeFirst()
        upcoming.removeFirst()
        start(.stream(request, title))
    }

    func togglePlayback() {
        switch soundtrack.state {
        case .playing, .buffering: soundtrack.pause()
        case .paused: soundtrack.resume()
        default: if let current { start(current) }
        }
    }

    func refreshRoute() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        routeKey = "sync.ms." + (output?.uid ?? "default")
        outputName = output?.portName ?? "Current output"
        correctionMS = UserDefaults.standard.double(forKey: routeKey)
    }

    func adjustSync(_ ms: Double) {
        correctionMS = ms
        UserDefaults.standard.set(ms, forKey: routeKey)
    }

    func interrupt() {
        stop()
        if soundtrack.state == .playing || soundtrack.state == .buffering { soundtrack.pause() }
    }

    func record() {
        guard phase == .idle, ready else { return }
        guard session.isRunning else { message = "Camera unavailable. Return to the app and try again."; return }
        do {
            try soundtrack.beginTake()
            let raw = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("mov")
            takeURL = raw
            videoStart = nil
            takeCorrection = correctionMS / 1000
            pendingStop = false
            phase = .starting
            message = "Starting camera."
            movie.startRecording(to: raw, recordingDelegate: self)
        } catch { message = error.localizedDescription }
    }

    func stop() {
        if phase == .starting { pendingStop = true; return }
        guard phase == .recording else { return }
        phase = .saving
        message = "Saving take."
        movie.stopRecording()
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                startPTS: CMTime, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            guard self.takeURL == fileURL, self.phase == .starting else { return }
            if let clock = self.session.synchronizationClock {
                let host = CMSyncConvertTime(startPTS, from: clock, to: CMClockGetHostTimeClock()).seconds
                if host.isFinite { self.videoStart = host }
            }
            self.phase = .recording
            self.message = "Recording."
            if self.pendingStop { self.stop() }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in await self.finish(fileURL, error: error as NSError?) }
    }

    private func finish(_ raw: URL, error: NSError?) async {
        guard raw == takeURL else { return }
        phase = .saving
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = library.appending(path: "Take-\(stamp)-\(UUID().uuidString.prefix(6))")
        var audio: SoundtrackTake?
        var validVideo = false
        defer {
            if let audio { try? FileManager.default.removeItem(at: audio.url) }
            takeURL = nil
            phase = .idle
        }
        do {
            if let error, (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
                soundtrack.discardTake()
                throw error
            }
            validVideo = true
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            audio = try await soundtrack.finishTake()
            var offset: Double = 0
            if let audio {
                guard let videoStart else { throw TakeError("Camera timestamps were unavailable.") }
                offset = audio.firstAudioHostTime - videoStart + takeCorrection
            }
            let saved = base.appendingPathExtension("mp4")
            let size = try await TakeExport.save(video: raw, audio: audio?.url, audioOffset: offset, to: saved)
            takes.insert(saved, at: 0)
            try? FileManager.default.removeItem(at: raw)
            message = "Saved \(Int(size.width)) × \(Int(size.height))."
        } catch {
            if validVideo {
                soundtrack.discardTake()
                let backup = base.appendingPathExtension("mov")
                do {
                    try FileManager.default.moveItem(at: raw, to: backup)
                    takes.insert(backup, at: 0)
                    message = "Saved camera video only. \(error.localizedDescription)"
                } catch { message = "Could not save the take. \(error.localizedDescription)" }
            } else {
                try? FileManager.default.removeItem(at: raw)
                message = error.localizedDescription
            }
        }
    }
}
