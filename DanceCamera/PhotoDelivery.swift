import SwiftUI
import Photos

@MainActor
final class PhotoDelivery: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var previousCount = 0
    @Published private(set) var delivering = false
    @Published var notice = ""
    @Published private(set) var latestAudioReport: URL?
    let pending = URL.applicationSupportDirectory.appending(path: "Pending Photos", directoryHint: .isDirectory)
    private let previous = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)
    private let reports = URL.documentsDirectory.appending(path: "Audio Reports", directoryHint: .isDirectory)

    init() {
        refresh()
        latestAudioReport = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "txt" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    func writeAudioReport(_ description: String, edits: MixerEdits?, originalTempo: Bool, recordedRates: [Double] = []) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
        let file = reports.appendingPathComponent(stamp.replacingOccurrences(of: ":", with: "-") + ".txt")
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = ["Dance Camera \(version)", stamp, description,
                     "Finish at original song tempo  " + (originalTempo ? "On" : "Off")]
        if !recordedRates.isEmpty {
            let rates = recordedRates.map { String(format: "%.2f×", $0) }.joined(separator: ", ")
            lines.append("Playback rates during video  " + rates)
        }
        if let edits { lines.append(edits.report) }
        do {
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            latestAudioReport = file
        } catch { latestAudioReport = nil }
    }

    private func movies(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
    }

    func refresh() {
        pendingCount = movies(in: pending).count
        previousCount = movies(in: previous).count
    }

    func destination() throws -> URL {
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        return pending.appending(path: "Dance-\(UUID().uuidString).mp4")
    }

    func save(includePrevious: Bool = false) async {
        refresh()
        guard !delivering, pendingCount > 0 || (includePrevious && previousCount > 0) else { return }
        delivering = true
        defer { delivering = false; refresh() }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            notice = "Allow Photos additions in Settings, then tap Retry. Your video is kept until it saves."
            return
        }
        do {
            var candidates = movies(in: pending)
            if includePrevious { candidates += movies(in: previous) }
            for url in candidates {
                try await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    // Photos takes ownership on success. Failed transactions leave the source available for retry.
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
                }
            }
            notice = candidates.count == 1 ? "Saved to Photos." : "\(candidates.count) videos saved to Photos."
        } catch { notice = "Photos could not finish saving. Tap Retry. \(error.localizedDescription)" }
    }
}
