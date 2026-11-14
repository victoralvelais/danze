import SwiftUI
import AVFoundation

struct TakeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum TakePhase { case idle, starting, recording, saving }

@MainActor
final class DanceRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVAudioPlayerDelegate {
    @Published var message = "Choose a soundtrack and frame the dancer."
    @Published private(set) var phase = TakePhase.idle
    @Published private(set) var ready = false
    @Published private(set) var songName: String?
    @Published private(set) var takes: [URL] = []
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private var music: URL?
    private var player: AVAudioPlayer?
    private var takeURL: URL?
    private var songOffset: Double?
    private var pendingStop = false
    private let library = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)

    override init() {
        super.init()
        takes = ((try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func configure() async {
        guard !ready else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Allow camera access in Settings to record a take."
            return
        }
        let capture = session, output = movie
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        if capture.inputs.isEmpty {
                            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            else { throw TakeError("No rear camera available.") }
                            let input = try AVCaptureDeviceInput(device: camera)
                            capture.beginConfiguration()
                            capture.automaticallyConfiguresApplicationAudioSession = false
                            if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
                            guard capture.canAddInput(input) else {
                                capture.commitConfiguration()
                                throw TakeError("Camera input is unavailable.")
                            }
                            capture.addInput(input)
                            guard capture.canAddOutput(output) else {
                                capture.removeInput(input)
                                capture.commitConfiguration()
                                throw TakeError("Video output is unavailable.")
                            }
                            capture.addOutput(output)
                            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                                connection.videoRotationAngle = 90
                            }
                            capture.commitConfiguration()
                        }
                        capture.startRunning()
                        guard capture.isRunning else { throw TakeError("The camera could not start.") }
                        done.resume()
                    } catch { done.resume(throwing: error) }
                }
            }
            ready = true
        } catch { message = error.localizedDescription }
    }

    func select(_ url: URL, title: String? = nil) throws {
        guard phase == .idle else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let imported = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: imported)
        do {
            let candidate = try AVAudioPlayer(contentsOf: imported)
            guard candidate.duration > 0 else { throw TakeError("Choose a playable audio file.") }
        } catch {
            try? FileManager.default.removeItem(at: imported)
            throw error
        }
        if let old = music { try? FileManager.default.removeItem(at: old) }
        music = imported
        songName = title ?? url.lastPathComponent
        message = "Ready to record."
    }

    func record() {
        guard phase == .idle, ready, let music else { return }
        guard session.isRunning else { message = "Camera unavailable. Return to the app and try again."; return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback)
            try audio.setActive(true)
            let track = try AVAudioPlayer(contentsOf: music)
            guard track.prepareToPlay() else { throw TakeError("Could not prepare the soundtrack.") }
            let raw = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("mov")
            takeURL = raw
            songOffset = nil
            pendingStop = false
            player = track
            track.delegate = self
            phase = .starting
            message = "Starting camera…"
            movie.startRecording(to: raw, recordingDelegate: self)
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false)
            message = error.localizedDescription
        }
    }

    func stop() {
        if phase == .starting { pendingStop = true; return }
        guard phase == .recording else { return }
        phase = .saving
        message = "Saving take…"
        player?.stop()
        movie.stopRecording()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                startPTS: CMTime, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            guard self.takeURL == fileURL, self.phase == .starting, let player = self.player else { return }
            self.phase = .recording
            guard !self.pendingStop, let clock = self.session.synchronizationClock else { self.stop(); return }
            let firstFrame = CMSyncConvertTime(startPTS, from: clock, to: CMClockGetHostTimeClock()).seconds
            let lead = 0.35
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard firstFrame.isFinite, player.play(atTime: player.deviceCurrentTime + lead) else { self.stop(); return }
            self.songOffset = max(0, hostNow + lead - firstFrame)
            self.message = "Recording with \(self.songName ?? "music")."
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in await self.finish(fileURL, error: error as NSError?) }
    }

    private func finish(_ raw: URL, error: NSError?) async {
        guard raw == takeURL else { return }
        phase = .saving
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer {
            try? FileManager.default.removeItem(at: raw)
            takeURL = nil
            phase = .idle
        }
        do {
            if let error, (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true { throw error }
            guard let music, let songOffset else { throw TakeError("Recording ended before the soundtrack started.") }
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let saved = library.appending(path: "Take-\(stamp)-\(UUID().uuidString.prefix(6)).mp4")
            try await Self.mix(video: raw, music: music, offset: songOffset, destination: saved)
            takes.insert(saved, at: 0)
            message = "Take saved on this iPhone."
        } catch { message = error.localizedDescription }
    }

    private nonisolated static func mix(video: URL, music: URL, offset: Double, destination: URL) async throws {
        let videoAsset = AVURLAsset(url: video), musicAsset = AVURLAsset(url: music)
        let timeline = AVMutableComposition()
        guard let image = try await videoAsset.loadTracks(withMediaType: .video).first,
              let song = try await musicAsset.loadTracks(withMediaType: .audio).first,
              let picture = timeline.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = timeline.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TakeError("A camera or soundtrack track is missing.") }
        let v = try await image.load(.timeRange), a = try await song.load(.timeRange)
        let delay = CMTime(seconds: offset, preferredTimescale: 48000)
        let common = CMTimeMinimum(v.duration - delay, a.duration)
        guard common.isNumeric, common > .zero else { throw TakeError("Record a longer take so it includes music.") }
        try picture.insertTimeRange(CMTimeRange(start: v.start + delay, duration: common), of: image, at: .zero)
        picture.preferredTransform = try await image.load(.preferredTransform)
        try sound.insertTimeRange(CMTimeRange(start: a.start, duration: common), of: song, at: .zero)
        guard let exporter = AVAssetExportSession(asset: timeline, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else { throw TakeError("MP4 export is unavailable.") }
        let temp = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await exporter.export(to: temp, as: .mp4)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
