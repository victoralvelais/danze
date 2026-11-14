import SwiftUI
import Photos

@MainActor
final class PhotoDelivery: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var previousCount = 0
    @Published private(set) var delivering = false
    @Published var notice = ""
    let pending = URL.applicationSupportDirectory.appending(path: "Pending Photos", directoryHint: .isDirectory)
    private let previous = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)

    init() { refresh() }

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
