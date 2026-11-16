import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import MediaPlayer
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
    let position: AVCaptureDevice.Position
    let configuring: Bool
    func makeUIView(context: Context) -> CameraCanvas {
        let view = CameraCanvas()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = session
        return view
    }

    func updateUIView(_ uiView: CameraCanvas, context: Context) {
        guard !configuring else { return }
        uiView.preview.connection?.setPortraitVideo(mirrored: position == .front)
    }

    static func dismantleUIView(_ uiView: CameraCanvas, coordinator: ()) { uiView.preview.session = nil }
}

struct DanceCameraView: View {
    @StateObject private var camera = DanceRecorder()
    @State private var cameraOpen = false
    @State private var choosing = false
    @State private var musicPicker = false
    @State private var libraryMessage = ""
    @Environment(\.scenePhase) private var scene

    var body: some View {
        NavigationStack {
            MusicLibrary(camera: camera, pickMusic: chooseMusic, pickFile: { choosing = true })
                .navigationTitle("Music")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        PlayerControls(camera: camera, music: camera.soundtrack)
                        if !libraryMessage.isEmpty { Text(libraryMessage).font(.caption) }
                        PhotoStatus(photos: camera.photos)
                        Button { cameraOpen = true } label: {
                            Label("Dance camera", systemImage: "video.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                    }.padding().background(.regularMaterial)
                }
        }
        .fullScreenCover(isPresented: $cameraOpen, onDismiss: { camera.releaseCamera() }) {
            CameraStudio(camera: camera)
        }
        .sheet(isPresented: $musicPicker) {
            SystemMusicPicker { item in
                musicPicker = false
                guard let item else { return }
                do { try camera.selectLibrary(item); libraryMessage = "" }
                catch { libraryMessage = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
            do { try camera.selectFile(result.get()); libraryMessage = "" }
            catch { if (error as NSError).code != NSUserCancelledError { libraryMessage = error.localizedDescription } }
        }
        #if targetEnvironment(simulator) && DEBUG
        .task {
            let file = URL.documentsDirectory.appending(path: "Live Rehearsal.wav")
            if ProcessInfo.processInfo.arguments.contains("-live-overlay-song-fixture"),
               camera.soundtrack.title.isEmpty, FileManager.default.fileExists(atPath: file.path) {
                try? camera.selectFile(file)
            }
        }
        #endif
        .onChange(of: scene) { _, phase in
            if phase == .background, cameraOpen { camera.interrupt(); camera.releaseCamera() }
            if phase == .active, cameraOpen { Task { await camera.configure() } }
        }
        .onReceive(camera.soundtrack.$state.removeDuplicates()) { if $0 == .ended { camera.playNext() } }
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
        }
    }

    private func chooseMusic() {
        MPMediaLibrary.requestAuthorization { status in
            Task { @MainActor in
                if status == .authorized { libraryMessage = ""; musicPicker = true }
                else { libraryMessage = "Allow Media & Apple Music access in Settings to browse your library." }
            }
        }
    }
}

private struct SystemMusicPicker: UIViewControllerRepresentable {
    let selected: (MPMediaItem?) -> Void
    class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let complete: (MPMediaItem?) -> Void
        init(_ complete: @escaping (MPMediaItem?) -> Void) { self.complete = complete }
        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            complete(collection.items.first)
        }
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) { complete(nil) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.showsCloudItems = false
        picker.allowsPickingMultipleItems = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}
}

private struct CameraStudio: View {
    @ObservedObject var camera: DanceRecorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var previousIdleTimer: Bool?
    @State private var liveSetup = false
    @State private var cleanCamera = false

    var body: some View {
        Group {
            if cleanCamera {
                FullscreenCamera(camera: camera, music: camera.soundtrack) { cleanCamera = false }
            } else {
                studio
            }
        }
        .statusBarHidden(cleanCamera)
        .persistentSystemOverlays(cleanCamera ? .hidden : .automatic)
        .sheet(isPresented: $liveSetup) {
            TikTokLiveSetup(camera: camera, onShowCleanCamera: {
                liveSetup = false
                cleanCamera = true
            })
        }
        .interactiveDismissDisabled(camera.phase != .idle || cleanCamera)
        .task { if scene == .active { await camera.configure() } }
        .onChange(of: scene, initial: true) { _, phase in
            setScreenAwake(phase == .active)
            if phase == .background && cleanCamera {
                // TikTok setup temporarily takes the camera and can pause the music.
                // On return, let the performer resume before hiding the controls.
                cleanCamera = false
                liveSetup = true
            }
        }
        .onDisappear { setScreenAwake(false) }
    }

    private var studio: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: { Label("Music", systemImage: "chevron.left") }
                    .disabled(camera.phase != .idle)
                Spacer()
                if camera.phase == .recording { Label("Recording", systemImage: "record.circle").foregroundStyle(.red) }
                Button { liveSetup = true } label: { Label("LIVE", systemImage: "dot.radiowaves.left.and.right") }
                    .disabled(camera.phase != .idle)
                    .accessibilityLabel("TikTok LIVE setup")
                if camera.hasOtherCamera {
                    Button { Task { await camera.switchCamera() } } label: {
                        Image(systemName: "camera.rotate").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(camera.position == .back ? "Switch to front camera" : "Switch to rear camera")
                    .disabled(!camera.ready || camera.configuring || camera.phase != .idle)
                }
            }
            ZStack {
                Color.black
                if camera.ready { Preview(session: camera.session, position: camera.position, configuring: camera.configuring) }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { cleanCamera = true } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.black.opacity(0.75), in: Capsule())
                }
                .foregroundStyle(.white).buttonStyle(.plain)
                .disabled(camera.phase != .idle)
                .accessibilityIdentifier("live.fullscreen")
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            PlayerControls(camera: camera, music: camera.soundtrack)
            Toggle("Finish at original song tempo", isOn: $camera.originalTempo)
                .font(.subheadline).disabled(camera.phase != .idle)
            if !camera.message.isEmpty { Text(camera.message).font(.caption) }
            PhotoStatus(photos: camera.photos)
            shutter
        }
        .padding()
    }

    private var shutter: some View {
        let canStop = camera.phase == .starting || camera.phase == .recording
        let saving = camera.phase == .saving
        return Button {
            if canStop { camera.stop() } else { camera.record() }
        } label: {
            ZStack {
                Circle().fill(.black)
                Circle().strokeBorder(.white, lineWidth: 3)
                if saving {
                    ProgressView().tint(.white)
                } else if canStop {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(.red).padding(7)
                }
            }
            .frame(width: 70, height: 70)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canStop && (!camera.ready || camera.configuring || saving))
        .accessibilityLabel(saving ? "Saving take" : canStop ? "Stop and save take" : "Record take")
    }

    private func setScreenAwake(_ awake: Bool) {
        let application = UIApplication.shared
        if awake {
            guard previousIdleTimer == nil else { return }
            previousIdleTimer = application.isIdleTimerDisabled
            application.isIdleTimerDisabled = true
        } else if let previousIdleTimer {
            application.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }
}

private struct FullscreenCamera: View {
    @ObservedObject var camera: DanceRecorder
    @ObservedObject var music: StreamingSoundtrack
    let onExit: () -> Void
    @AppStorage("live.camera.fillsFrame") private var fillsFrame = true
    @AppStorage("live.camera.showsSong") private var showsSong = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scene
    @State private var controls = false
    @State private var microphone = false
    @State private var activity = UUID()

    var body: some View {
        ZStack {
            ZStack {
                Color.black
                CleanCameraSurface(camera: camera, fillsFrame: fillsFrame)
                if let problem = camera.cleanIssue ?? (!camera.ready && !camera.message.isEmpty ? camera.message : nil) {
                    Text(problem).foregroundStyle(.white).padding()
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controls ? "Hide camera controls" : "Show camera controls")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("live.reveal")
            .accessibilityAction { toggleControls() }
            .accessibilityAction(.escape) { onExit() }

            VStack(alignment: .leading) {
                if showsSong, let status = songStatus, !music.title.isEmpty {
                    let line = status.isEmpty ? music.title : "\(status) · \(music.title)"
                    Label(line, systemImage: "music.note")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(status.isEmpty ? "Now playing, \(music.title)" : line)
                        .accessibilityIdentifier("live.nowPlaying")
                        .allowsHitTesting(false)
                }
                Spacer()
                if controls { hostControls }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $microphone) { BroadcastMicrophoneSheet() }
        .task(id: activity) {
            guard controls, !voiceOver, !microphone, scene == .active else { return }
            #if targetEnvironment(simulator) && DEBUG
            // Accessibility queries on the CI simulator can take longer than the
            // panel timeout. A separate UI test exercises the normal five seconds.
            if ProcessInfo.processInfo.arguments.contains("-inspect-live-host-controls") { return }
            #endif
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            controls = false
        }
        .onChange(of: scene) { _, _ in activity = UUID() }
        .onChange(of: voiceOver) { _, _ in activity = UUID() }
        .onChange(of: microphone) { _, _ in activity = UUID() }
    }

    private var songStatus: String? {
        switch music.state {
        case .playing: return ""
        case .paused: return "Paused"
        case .buffering: return "Loading"
        case .idle, .ended, .failed: return nil
        }
    }

    private func toggleControls() {
        controls.toggle()
        activity = UUID()
    }

    private var hostControls: some View {
        VStack(spacing: 4) {
            HStack {
                Button { onExit() } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("live.exit")
                Spacer()
                if !music.title.isEmpty {
                    let active = music.state == .playing || music.state == .buffering
                    Button {
                        camera.togglePlayback()
                        activity = UUID()
                    } label: {
                        Image(systemName: active ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(active ? "Pause music" : (music.state == .paused ? "Resume music" : "Play music"))
                    .accessibilityIdentifier("live.playback")
                }
                Button("Hide") { toggleControls() }.frame(minHeight: 44)
                    .accessibilityLabel("Hide controls").accessibilityIdentifier("live.hide")
            }
            Divider().overlay(.white.opacity(0.4))
            HStack {
                Button {
                    fillsFrame.toggle()
                    activity = UUID()
                } label: {
                    Label(fillsFrame ? "Fill" : "Fit", systemImage: "aspectratio").frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Camera framing").accessibilityValue(fillsFrame ? "Fill" : "Fit")
                .accessibilityHint(fillsFrame ? "Show the entire frame" : "Fill the screen")
                .accessibilityIdentifier("live.framing")
                Button {
                    showsSong.toggle()
                    activity = UUID()
                } label: {
                    Label("Song", systemImage: showsSong ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Show current song").accessibilityValue(showsSong ? "On" : "Off")
                .accessibilityIdentifier("live.toggleSong")
                Button { microphone = true } label: {
                    Label("Mic", systemImage: "mic").frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Broadcast microphone controls").accessibilityIdentifier("live.microphone")
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PlayerControls: View {
    @ObservedObject var camera: DanceRecorder
    @ObservedObject var music: StreamingSoundtrack
    var body: some View {
        if !music.title.isEmpty {
            VStack(spacing: 5) {
                HStack {
                    Button { camera.togglePlayback() } label: {
                        let active = music.state == .playing || music.state == .buffering
                        Image(systemName: active ? "pause.fill" : "play.fill")
                            .accessibilityLabel(active ? "Pause" : "Play")
                    }.buttonStyle(.bordered)
                    Text(music.title).font(.headline).lineLimit(2)
                    Spacer()
                    if !camera.upcoming.isEmpty {
                        Button { camera.playNext() } label: { Image(systemName: "forward.end.fill").accessibilityLabel("Next song") }
                    }
                }
                HStack {
                    Text("Speed").font(.caption)
                    Slider(value: Binding(get: { camera.speed }, set: { camera.changeSpeed($0) }),
                           in: 0.5...2, step: 0.01).accessibilityLabel("Song speed")
                    Button { camera.changeSpeed(1) } label: {
                        Text(String(format: "%.2f×", camera.speed)).font(.subheadline.monospacedDigit())
                    }.accessibilityHint("Reset song speed")
                }
                if music.state == .buffering { ProgressView("Buffering audio").font(.caption) }
                if case let .failed(problem) = music.state { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

private struct PhotoStatus: View {
    @ObservedObject var photos: PhotoDelivery
    var body: some View {
        VStack(spacing: 3) {
            if !photos.notice.isEmpty { Text(photos.notice).font(.caption) }
            if let report = photos.latestAudioReport {
                ShareLink("Share latest audio report", item: report).font(.caption)
            }
            if photos.pendingCount > 0 && !photos.delivering {
                Button("Retry saving to Photos") { Task { await photos.save() } }
            }
            if photos.previousCount > 0 {
                Button("Move \(photos.previousCount) previous clips to Photos") {
                    Task { await photos.save(includePrevious: true) }
                }.disabled(photos.delivering)
            }
        }
    }
}
