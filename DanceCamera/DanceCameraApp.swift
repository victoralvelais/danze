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
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: { Label("Music", systemImage: "chevron.left") }
                    .disabled(camera.phase != .idle)
                Spacer()
                if camera.phase == .recording { Label("Recording", systemImage: "record.circle").foregroundStyle(.red) }
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
            }.clipShape(RoundedRectangle(cornerRadius: 14))
            PlayerControls(camera: camera, music: camera.soundtrack)
            Toggle("Finish at original song tempo", isOn: $camera.originalTempo)
                .font(.subheadline).disabled(camera.phase != .idle)
            if !camera.message.isEmpty { Text(camera.message).font(.caption) }
            PhotoStatus(photos: camera.photos)
            shutter
        }
        .padding()
        .interactiveDismissDisabled(camera.phase != .idle)
        .task { if scene == .active { await camera.configure() } }
        .onChange(of: scene, initial: true) { _, phase in setScreenAwake(phase == .active) }
        .onDisappear { setScreenAwake(false) }
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
