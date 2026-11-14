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
    @State private var account = LibraryAccount()
    @State private var savedClipsOpen = false
    @Environment(\.scenePhase) private var scene
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Color.black
                    if camera.ready { Preview(session: camera.session) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(camera.message).font(.subheadline)
                if let name = camera.songName { Text(name).font(.headline) }
                HStack {
                    Button("Choose from Navidrome") { libraryOpen = true }.buttonStyle(.bordered)
                    Button("Files") { choosing = true }
                }.disabled(camera.phase != .idle)
                if camera.phase == .recording {
                    Button("Stop and save") { camera.stop() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Record take") { camera.record() }.buttonStyle(.borderedProminent)
                        .disabled(!camera.ready || camera.songName == nil || camera.phase != .idle)
                }
                if !camera.takes.isEmpty {
                    Button("Saved clips (\(camera.takes.count))") { savedClipsOpen = true }
                        .disabled(camera.phase != .idle)
                }
            }
            .padding()
            .navigationTitle("Dance Camera")
        }
        .task { await camera.configure() }
        .onChange(of: scene) { _, value in if value == .background { camera.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                camera.stop()
            }
        }
        .sheet(isPresented: $libraryOpen) {
            MusicLibrary(account: $account) { try camera.select($0, title: $1) }
        }
        .sheet(isPresented: $savedClipsOpen) { SavedClips(takes: camera.takes) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
            do { try camera.select(result.get()) }
            catch { if (error as NSError).code != NSUserCancelledError { camera.message = error.localizedDescription } }
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
