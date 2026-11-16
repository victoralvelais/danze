import ReplayKit
import SwiftUI

struct TikTokLiveSetup: View {
    private let camera: DanceRecorder
    @ObservedObject private var music: StreamingSoundtrack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSceneCaptured) private var sceneCaptured
    @State private var captureEnded = false
    #if targetEnvironment(simulator) && DEBUG
    private static let simulatesCapture = ProcessInfo.processInfo.arguments.contains("-live-picker-capture-fixture")
    @State private var fixtureCaptured = false
    #endif
    let onShowCleanCamera: () -> Void

    init(camera: DanceRecorder, onShowCleanCamera: @escaping () -> Void) {
        self.camera = camera
        self.music = camera.soundtrack
        self.onShowCleanCamera = onShowCleanCamera
    }

    private var playbackAction: String? {
        guard !music.title.isEmpty else { return nil }
        switch music.state {
        case .paused: return "Resume music"
        case .ended, .failed, .idle: return "Play music"
        case .playing, .buffering: return nil
        }
    }

    private var captured: Bool {
        #if targetEnvironment(simulator) && DEBUG
        if Self.simulatesCapture { return fixtureCaptured }
        #endif
        return sceneCaptured
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The system control stays mounted outside Form's recyclable rows.
                // Capture-state changes update the adjacent copy only.
                VStack(alignment: .leading, spacing: 6) {
                    Text(captured ? "Screen capture active" : captureEnded ? "Screen capture ended" : "Start screen broadcast")
                        .font(.headline).accessibilityIdentifier("live.captureStatus")
                    HStack(spacing: 12) {
                        BroadcastPicker()
                            .frame(width: 52, height: 52)
                            .background(.quaternary, in: Circle())
                            .accessibilityLabel(captured || captureEnded ? "Open iPhone broadcast controls" : "Start screen broadcast")
                            .accessibilityIdentifier("live.startBroadcast")
                        if captureEnded {
                            Text("Open LIVE in TikTok, choose Mobile gaming, and start sharing there. When TikTok confirms your LIVE, return here and tap Show clean camera.")
                                .accessibilityIdentifier("live.captureRecovery")
                        } else {
                            Text(captured ? "Check your LIVE status in TikTok. When you’re ready, tap Show clean camera." :
                                "Tap the broadcast button. Choose TikTok if listed and confirm in iOS. Check your LIVE status in TikTok.")
                        }
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                Form {
                    Section("Camera") {
                        Button("Show clean camera") { onShowCleanCamera() }
                            .accessibilityIdentifier("live.showCleanCamera")
                        if let playbackAction {
                            Button(playbackAction) { camera.togglePlayback() }
                        }
                        if music.state == .buffering { ProgressView("Starting music") }
                        if case .failed = music.state {
                            Text("Music stopped. Tap Play music to restart the selected song.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Tap the fullscreen picture to show the host controls.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !captureEnded {
                        Section("TikTok Mobile gaming") {
                            Text(captured ? "Manage or end your TikTok LIVE in TikTok." :
                                "If TikTok is missing from the picker or needs setup, open LIVE in TikTok and choose Mobile gaming. Start sharing there, then return to Dance Camera.")
                        }
                    }
                    Section("Try a private rehearsal") {
                        Text("Open the clean camera and start Screen Recording from Control Center. Choose Photos as the destination. Stop recording and play it back to check the picture and music.")
                    }
                }
            }
            .navigationTitle("TikTok LIVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: captured) { wasCaptured, active in captureEnded = wasCaptured && !active }
            #if targetEnvironment(simulator) && DEBUG
            .task {
                guard Self.simulatesCapture else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                    fixtureCaptured = true
                    try await Task.sleep(for: .seconds(3))
                    fixtureCaptured = false
                } catch { return }
            }
            #endif
        }
        .interactiveDismissDisabled()
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
