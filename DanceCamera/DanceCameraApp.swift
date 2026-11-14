import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AVKit
import Photos

@main
struct DanceCameraApp: App {
    var body: some Scene { WindowGroup { DanceCameraView() } }
}

private final class CameraCanvas: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraCanvas {
        let view = CameraCanvas()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = session
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: CameraCanvas, context: Context) {}
}

struct DanceCameraView: View {
    @StateObject private var camera = DanceRecorder()
    @State private var choosing = false
    @State private var libraryOpen = false
    @State private var syncOpen = false
    @State private var account = LibraryAccount()
    @State private var savedClipsOpen = false
    @Environment(\.scenePhase) private var scene

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Color.black
                    if camera.ready { Preview(session: camera.session) }
                    if !camera.quality.isEmpty {
                        Text(camera.quality).font(.caption.bold())
                            .padding(8).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(8)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                Text(camera.message).font(.footnote)
                Transport(camera: camera, music: camera.soundtrack)
                HStack {
                    Button("Navidrome") { libraryOpen = true }.buttonStyle(.bordered)
                    Button("Files") { choosing = true }
                    Spacer()
                    if camera.phase == .starting || camera.phase == .recording {
                        Button("Stop and save") { camera.stop() }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button(camera.phase == .saving ? "Saving…" : "Record take") { camera.record() }
                            .buttonStyle(.borderedProminent).disabled(!camera.ready || camera.phase != .idle)
                    }
                }
            }
            .padding()
            .navigationTitle("Dance Camera").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Audio sync") { camera.refreshRoute(); syncOpen = true }.disabled(camera.phase != .idle)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clips (\(camera.takes.count))") {
                        if camera.soundtrack.state == .playing || camera.soundtrack.state == .buffering { camera.soundtrack.pause() }
                        savedClipsOpen = true
                    }.disabled(camera.takes.isEmpty || camera.phase != .idle)
                }
            }
        }
        .task { await camera.configure() }
        .onChange(of: scene) { _, value in
            if value == .background { camera.interrupt() }
            if value == .active { camera.refreshRoute(); Task { await camera.configure() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                camera.interrupt()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs.map(\.uid)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid)
            if let previous, !previous.isEmpty, previous != outputs,
               reason == .oldDeviceUnavailable || reason == .newDeviceAvailable || reason == .override {
                camera.interrupt()
            }
            camera.refreshRoute()
        }
        .sheet(isPresented: $libraryOpen) {
            MusicLibrary(account: $account) { camera.selectStream($0, title: $1, enqueue: $2) }
        }
        .sheet(isPresented: $syncOpen) { SyncSettings(camera: camera).presentationDetents([.medium]) }
        .sheet(isPresented: $savedClipsOpen) { SavedClips(takes: camera.takes) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
            do { try camera.selectFile(result.get()) }
            catch { if (error as NSError).code != NSUserCancelledError { camera.message = error.localizedDescription } }
        }
    }
}

private struct Transport: View {
    @ObservedObject var camera: DanceRecorder
    @ObservedObject var music: StreamingSoundtrack

    var body: some View {
        if !music.title.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { camera.togglePlayback() } label: {
                        let active = music.state == .playing || music.state == .buffering
                        Image(systemName: active ? "pause.fill" : "play.fill")
                            .accessibilityLabel(active ? "Pause" : "Play")
                    }.buttonStyle(.bordered)
                    Text(music.title).font(.headline).lineLimit(2)
                    Spacer()
                    if !camera.upcoming.isEmpty {
                        Button { camera.playNext() } label: {
                            Image(systemName: "forward.end.fill").accessibilityLabel("Next song")
                        }.buttonStyle(.bordered)
                    }
                }
                if music.state == .buffering { ProgressView("Buffering audio").font(.caption) }
                if case .failed(let problem) = music.state { Text(problem).font(.footnote).foregroundStyle(.red) }
                if let next = camera.upcoming.first { Text("Up next · \(next)").font(.caption).lineLimit(1) }
            }
            .onChange(of: music.state) { _, value in if value == .ended { camera.playNext() } }
        }
    }
}

private struct SyncSettings: View {
    @ObservedObject var camera: DanceRecorder
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(camera.outputName) {
                    Text("The app applies output latency automatically. Use this adjustment if the saved clip still looks off.")
                    Text("Soundtrack shift: \(Int(camera.correctionMS)) ms").monospacedDigit()
                    Slider(value: Binding(get: { camera.correctionMS }, set: { camera.adjustSync($0) }),
                           in: -500...500, step: 10).accessibilityLabel("Soundtrack shift in milliseconds")
                    Text("If the beat comes before the movement, move right. If it comes after, move left. Changes apply to your next take.")
                        .font(.footnote)
                    Button("Reset adjustment") { camera.adjustSync(0) }
                }
            }
            .navigationTitle("Audio sync").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct SavedClips: View {
    let takes: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var message = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                if let player { VideoPlayer(player: player).frame(height: 260) }
                if !message.isEmpty { Text(message).font(.footnote) }
                ForEach(takes, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 8) {
                        Button(url.deletingPathExtension().lastPathComponent) {
                            player?.pause()
                            player = AVPlayer(url: url)
                            player?.play()
                        }.accessibilityHint("Play this clip")
                        HStack {
                            Button("Save to Photos") { saveToPhotos(url) }.disabled(saving)
                            Spacer()
                            ShareLink("Share", item: url)
                        }.font(.subheadline)
                    }.buttonStyle(.borderless)
                }
            }
            .navigationTitle("Saved clips")
            .toolbar { Button("Done") { dismiss() } }
        }.onDisappear { player?.pause() }
    }

    private func saveToPhotos(_ url: URL) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                message = "Photos access is off. Your clip is in Saved clips. Use Share, then Save to Files."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
                message = "Clip saved to Photos."
            } catch { message = error.localizedDescription }
        }
    }
}
