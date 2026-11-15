import SwiftUI
import AVFoundation
import CryptoKit
import MediaPlayer

enum TakePhase { case idle, starting, recording, saving }

extension AVCaptureConnection {
    func setPortraitVideo(mirrored: Bool) {
        // The studio is portrait-only. Let AVFoundation map portrait to the
        // attached sensor, including front cameras with a different mounting angle.
        if isVideoOrientationSupported && videoOrientation != .portrait { videoOrientation = .portrait }
        if isVideoMirroringSupported {
            if automaticallyAdjustsVideoMirroring { automaticallyAdjustsVideoMirroring = false }
            if isVideoMirrored != mirrored { isVideoMirrored = mirrored }
        }
    }
}

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
    @Published private(set) var configuring = false
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var hasOtherCamera = false
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
        await updateCamera(to: nil)
    }

    func switchCamera() async {
        guard wantsCamera, ready, hasOtherCamera, phase == .idle, !configuring else { return }
        await updateCamera(to: position == .back ? .front : .back)
    }

    private func updateCamera(to requested: AVCaptureDevice.Position?) async {
        guard !configuring, requested == nil || (wantsCamera && ready && phase == .idle) else { return }
        configuring = true
        defer {
            configuring = false
            if !wantsCamera { releaseCamera() }
        }
        if requested == nil {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                message = "Allow camera access in Settings to record a take."
                return
            }
        }
        guard wantsCamera else { return }
        let capture = session, output = movie
        let state: (position: AVCaptureDevice.Position?, ready: Bool, other: Bool, issue: String?) = await withCheckedContinuation { done in
            sessionQueue.async {
                var issue: String?
                do {
                    try Self.installCamera(on: capture, output: output, requested: requested)
                    if !capture.isRunning { capture.startRunning() }
                    if !capture.isRunning { throw TakeError("The camera could not start.") }
                } catch { issue = error.localizedDescription }
                let active = Self.videoInput(in: capture)?.device.position
                let other = active.map { Self.wideCamera(at: $0 == .back ? .front : .back) != nil } ?? false
                let usable = capture.isRunning && active != nil && output.connection(with: .video) != nil
                done.resume(returning: (active, usable, other, issue))
            }
        }
        if let active = state.position { position = active }
        hasOtherCamera = state.other
        ready = wantsCamera && state.ready
        message = state.issue ?? ""
    }

    nonisolated private static func wideCamera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    nonisolated private static func videoInput(in capture: AVCaptureSession) -> AVCaptureDeviceInput? {
        capture.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }
    }

    // Runs on sessionQueue. Replacing the video input preserves the movie output
    // and the separate music playback graph between takes.
    nonisolated private static func installCamera(on capture: AVCaptureSession, output: AVCaptureMovieFileOutput,
                                                 requested: AVCaptureDevice.Position?) throws {
        let previous = videoInput(in: capture)
        if requested == nil, previous != nil, output.connection(with: .video) != nil { return }
        let device: AVCaptureDevice?
        if let requested { device = wideCamera(at: requested) }
        else { device = previous?.device ?? wideCamera(at: .back) ?? wideCamera(at: .front) }
        guard let device else { throw TakeError("The requested camera is unavailable.") }
        let input = try AVCaptureDeviceInput(device: device)
        let oldPreset = capture.sessionPreset
        let hadOutput = capture.outputs.contains { $0 === output }
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        capture.automaticallyConfiguresApplicationAudioSession = false
        // The previous lens may support a higher preset than the new lens.
        if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
        if let previous { capture.removeInput(previous) }
        do {
            guard capture.canAddInput(input) else { throw TakeError("Could not use that camera.") }
            capture.addInput(input)
            if !hadOutput {
                guard capture.canAddOutput(output) else { throw TakeError("Video output is unavailable.") }
                capture.addOutput(output)
            }
            let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            if let best = presets.first(where: { capture.canSetSessionPreset($0) }) { capture.sessionPreset = best }
            try configureMovieConnection(output)
        } catch {
            if !hadOutput && capture.outputs.contains(where: { $0 === output }) { capture.removeOutput(output) }
            if capture.inputs.contains(where: { $0 === input }) { capture.removeInput(input) }
            if let previous {
                if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
                guard capture.canAddInput(previous) else { throw TakeError("Camera unavailable. Reopen Dance camera to retry.") }
                capture.addInput(previous)
                if capture.canSetSessionPreset(oldPreset) { capture.sessionPreset = oldPreset }
                if hadOutput { try configureMovieConnection(output) }
            }
            throw error
        }
    }

    nonisolated private static func configureMovieConnection(_ output: AVCaptureMovieFileOutput) throws {
        guard let connection = output.connection(with: .video) else { throw TakeError("Video connection is unavailable.") }
        connection.setPortraitVideo(mirrored: false)
        let codecs: [AVVideoCodecType] = [.hevc, .h264]
        if let codec = codecs.first(where: { output.availableVideoCodecTypes.contains($0) }) {
            output.setOutputSettings([AVVideoCodecKey: codec], for: connection)
        }
    }

    func releaseCamera() {
        wantsCamera = false
        guard phase == .idle else { return }
        ready = false
        guard !configuring else { return } // The in-flight update reconciles wantsCamera before releasing.
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
        guard wantsCamera, phase == .idle, ready, !configuring else { return }
        guard session.isRunning else { message = "Camera unavailable. Return to the app and try again."; return }
        do {
            try soundtrack.beginTake(restoreTempo: originalTempo)
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
        soundtrack.stoppingCamera()
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
                let export = try await TakeExport.save(video: raw, audio: audio?.url, audioOffset: offset,
                                                       speeds: audio?.speedChanges ?? [], restoreTempo: restoreTempo,
                                                       videoStart: videoStart ?? 0, source: audio?.source,
                                                       sourceFallback: audio?.sourceFallback ?? .noAnchor, to: saved)
                photos.writeAudioReport(export.audioPath.description, edits: audio?.mixerEdits, originalTempo: restoreTempo,
                                        recordedRates: export.recordedRates)
                try? FileManager.default.removeItem(at: raw)
                message = ""
            } catch {
                soundtrack.discardTake()
                try FileManager.default.moveItem(at: raw, to: saved.deletingPathExtension().appendingPathExtension("mov"))
                photos.writeAudioReport("Camera video only after soundtrack export failed.", edits: audio?.mixerEdits, originalTempo: restoreTempo)
                message = "Camera video only. \(error.localizedDescription)"
            }
            await photos.save()
        } catch { message = "Could not finish saving the camera video. \(error.localizedDescription)" }
    }
}
