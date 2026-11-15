import ReplayKit
import SwiftUI

struct TikTokLiveSetup: View {
    @ObservedObject private var camera: DanceRecorder
    @ObservedObject private var music: StreamingSoundtrack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.isSceneCaptured) private var captured
    @State private var captureBegan = false
    @State private var waitingForMusic = false
    let onShowCleanCamera: () -> Void

    init(camera: DanceRecorder, onShowCleanCamera: @escaping () -> Void) {
        self.camera = camera
        self.music = camera.soundtrack
        self.onShowCleanCamera = onShowCleanCamera
    }

    private var playbackAction: String? {
        guard !music.title.isEmpty else { return nil }
        switch music.state {
        case .paused: return "Resume music and show clean camera"
        case .ended, .failed, .idle: return "Play music and show clean camera"
        case .playing, .buffering: return nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mobile gaming") {
                    Text("In TikTok, open LIVE and choose Mobile gaming. Start sharing your screen there, then return to Dance Camera.")
                    Button("Show clean camera") { onShowCleanCamera() }
                        .accessibilityIdentifier("live.showCleanCamera")
                    if let playbackAction {
                        Button(playbackAction) {
                            waitingForMusic = true
                            camera.togglePlayback()
                        }
                        .disabled(waitingForMusic)
                    }
                    if waitingForMusic { ProgressView("Starting music") }
                    if case .failed = music.state {
                        Text("Music stopped. Tap Play music to restart the selected song.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Tap the clean camera picture to bring back the controls. End your LIVE in TikTok.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("iPhone broadcast picker") {
                    HStack {
                        Text("Choose a broadcast provider")
                        Spacer()
                        BroadcastPicker()
                            .frame(width: 48, height: 48)
                            .accessibilityIdentifier("systemBroadcastPicker")
                    }
                    Text("Choose TikTok if it appears. iOS shows the broadcast providers installed on this phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Try a private rehearsal") {
                    Text("Open the clean camera and start Screen Recording from Control Center. Choose Photos as the destination. Stop recording and play it back to check the picture and music.")
                }
            }
            .navigationTitle("TikTok LIVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            // Only a transition while setup is open triggers the clean view.
            // Returning to settings during an existing recording stays possible.
            .onChange(of: captured) { _, active in
                captureBegan = active
                showCapturedCameraIfReady()
            }
            .onChange(of: scene) { _, _ in showCapturedCameraIfReady() }
            .onChange(of: camera.ready) { _, _ in showCapturedCameraIfReady() }
            .onChange(of: music.state) { _, state in
                guard waitingForMusic else { return }
                switch state {
                case .playing:
                    waitingForMusic = false
                    if scene == .active { onShowCleanCamera() }
                case .failed, .paused, .ended, .idle: waitingForMusic = false
                case .buffering: break
                }
            }
        }
    }

    private func showCapturedCameraIfReady() {
        guard captureBegan, captured, scene == .active, camera.ready, !waitingForMusic, playbackAction == nil else { return }
        captureBegan = false
        onShowCleanCamera()
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        picker.preferredExtension = nil
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
