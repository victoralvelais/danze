import SwiftUI
import AVFoundation
import CryptoKit
import MediaPlayer

enum TakePhase { case idle, starting, recording, saving }

@MainActor
final class DanceRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var message = ""
    @Published private(set) var phase = TakePhase.idle
    @Published private(set) var ready = false
    @Published private(set) var upcoming: [String] = []
    @Published private(set) var speed = 1.0
    @Published var originalTempo = false
    let photos = PhotoDelivery()
    let session = AVCaptureSession()
    let soundtrack = StreamingSoundtrack()
    private let movie = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var wantsCamera = false
    private var configuring = false
    private enum Source { case stream(URLRequest, String), file(URL, String), library(URL, String) }
    private var current: Source?
    private var currentKey = ""
    private var next: [(Source, String)] = []
    private var takeURL: URL?
    private var videoStart: Double?
    private var restoreTempo = false
    private var pendingStop = false

    func configure() async {
        wantsCamera = true
        guard !ready, !configuring else { return }
        configuring = true
        defer { configuring = false }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Allow camera access in Settings to record a take."
            return
        }
        guard wantsCamera else { return }
        let capture = session, output = movie
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
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
                        done.resume()
                    } catch { done.resume(throwing: error) }
                }
            }
            ready = wantsCamera
            if ready { message = "" } else { releaseCamera() }
        } catch { message = error.localizedDescription }
    }

    func releaseCamera() {
        wantsCamera = false
        guard phase == .idle else { return }
        ready = false
        let capture = session
        sessionQueue.async { if capture.isRunning { capture.stopRunning() } }
    }

    func selectFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: local)
        start(.file(local, url.lastPathComponent), key: "file:" + url.absoluteString)
    }

    func selectLibrary(_ item: MPMediaItem) throws {
        guard !item.hasProtectedAsset, let url = item.assetURL else {
            throw TakeError("This song has no recordable audio available. Choose a downloaded, unprotected Music track.")
        }
        start(.library(url, item.title ?? "Music track"), key: "music:" + String(item.persistentID))
    }

    func selectStream(_ request: URLRequest, title: String, key: String, enqueue: Bool) {
        if enqueue, current != nil, [.playing, .buffering, .paused].contains(soundtrack.state) {
            next.append((.stream(request, title), key))
            upcoming.append(title)
        } else { start(.stream(request, title), key: key) }
    }

    private func start(_ source: Source, key: String) {
        let previous = current
        current = source
        currentKey = "song.rate." + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        speed = (UserDefaults.standard.object(forKey: currentKey) as? Double) ?? 1
        soundtrack.setRate(speed)
        switch source {
        case let .stream(request, title): soundtrack.play(request, title: title)
        case let .file(url, title): soundtrack.play(url, title: title)
        case let .library(url, title): soundtrack.playLibrary(url, title: title)
        }
        if case let .file(old, _)? = previous, case let .file(new, _) = source, old == new { return }
        if case let .file(old, _)? = previous { try? FileManager.default.removeItem(at: old) }
    }

    func playNext() {
        guard !next.isEmpty else { return }
        let (song, key) = next.removeFirst()
        upcoming.removeFirst()
        start(song, key: key)
    }

    func togglePlayback() {
        switch soundtrack.state {
        case .playing, .buffering: soundtrack.pause()
        case .paused: soundtrack.resume()
        default:
            guard let current else { return }
            switch current {
            case let .file(url, title): soundtrack.play(url, title: title)
            case let .stream(request, title): soundtrack.play(request, title: title)
            case let .library(url, title): soundtrack.playLibrary(url, title: title)
            }
            soundtrack.setRate(speed)
        }
    }

    func changeSpeed(_ value: Double) {
        guard !currentKey.isEmpty else { return }
        let tuned = min(2, max(0.5, (value * 100).rounded() / 100))
        guard tuned != speed else { return }
        speed = tuned
        soundtrack.setRate(tuned)
        UserDefaults.standard.set(tuned, forKey: currentKey)
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
            restoreTempo = originalTempo
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
        var audio: SoundtrackTake?
        defer {
            if let audio { try? FileManager.default.removeItem(at: audio.url) }
            takeURL = nil
            phase = .idle
            if !wantsCamera { releaseCamera() }
        }
        if let error, (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
            soundtrack.discardTake()
            try? FileManager.default.removeItem(at: raw)
            message = error.localizedDescription
            return
        }
        do {
            let saved = try photos.destination()
            do {
                audio = try await soundtrack.finishTake()
                var offset: Double = 0
                if let audio {
                    guard let videoStart else { throw TakeError("Camera timestamps were unavailable.") }
                    offset = audio.firstAudioHostTime - videoStart
                }
                _ = try await TakeExport.save(video: raw, audio: audio?.url, audioOffset: offset,
                                              speeds: restoreTempo ? audio?.speedChanges ?? [] : [],
                                              videoStart: videoStart ?? 0, to: saved)
                try? FileManager.default.removeItem(at: raw)
                message = ""
            } catch {
                soundtrack.discardTake()
                try FileManager.default.moveItem(at: raw, to: saved.deletingPathExtension().appendingPathExtension("mov"))
                message = "Camera video only. \(error.localizedDescription)"
            }
            await photos.save()
        } catch { message = "Could not finish saving the camera video. \(error.localizedDescription)" }
    }
}
