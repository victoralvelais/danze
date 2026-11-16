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
                Section(captured ? "Broadcast controls" : "Start screen broadcast") {
                    HStack(spacing: 12) {
                        BroadcastPicker()
                            .frame(width: 52, height: 52)
                            .background(.quaternary, in: Circle())
                            .accessibilityLabel(captured ? "Open broadcast controls" : "Start screen broadcast")
                            .accessibilityIdentifier("live.startBroadcast")
                        Text(captured ? "iOS is capturing this screen. Tap the broadcast button for system controls." :
                            "Tap the broadcast button. Choose TikTok if listed, then confirm in iOS to share your screen.")
                            .font(.subheadline)
                    }
                }
                Section("Camera") {
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
                    Text("Tap the fullscreen picture to show the host controls.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("TikTok Mobile gaming") {
                    Text(captured ? "Manage or end your TikTok LIVE in TikTok." :
                        "If TikTok is missing from the picker or needs setup, open LIVE in TikTok and choose Mobile gaming. Start sharing there, then return to Dance Camera.")
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

struct BroadcastMicrophoneSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Broadcast microphone") {
                    HStack {
                        Text("Open iPhone broadcast controls")
                        Spacer()
                        BroadcastPicker()
                            .frame(width: 48, height: 48)
                            .accessibilityIdentifier("live.systemMicPicker")
                    }
                    Text("Use Microphone in the iPhone broadcast controls to turn your voice on or off when available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("While sharing in TikTok") {
                    Text("Swipe down from the top-right corner to open Control Center. Touch and hold Screen Recording and look for Microphone. If TikTok manages your mic, use its LIVE audio controls.")
                }
            }
            .navigationTitle("Microphone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("live.closeMic")
                }
            }
        }
        .presentationDetents([.medium, .large])
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
