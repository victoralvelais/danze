import AVFoundation

enum TakeExport {
    struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // The offset is signed: the tap can already be playing when the camera starts.
    static func save(video: URL, audio: URL?, audioOffset: Double, to destination: URL) async throws -> CGSize {
        let videoAsset = AVURLAsset(url: video)
        let timeline = AVMutableComposition()
        guard let image = try await videoAsset.loadTracks(withMediaType: .video).first,
              let picture = timeline.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError("The camera file has no video track.") }
        let v = try await image.load(.timeRange)
        try picture.insertTimeRange(v, of: image, at: .zero)
        picture.preferredTransform = try await image.load(.preferredTransform)
        let size = try await image.load(.naturalSize)

        let aac = temporaryFile("m4a"), mp4 = temporaryFile("mp4")
        defer {
            try? FileManager.default.removeItem(at: aac)
            try? FileManager.default.removeItem(at: mp4)
        }
        if let audio {
            try await addSoundtrack(audio, offset: audioOffset, videoDuration: v.duration, to: timeline, temporaryAAC: aac)
        }
        guard let mux = AVAssetExportSession(asset: timeline, presetName: AVAssetExportPresetPassthrough),
              mux.supportedFileTypes.contains(.mp4) else { throw ExportError("The camera format could not be packaged as MP4.") }
        try await mux.export(to: mp4, as: .mp4)
        try FileManager.default.moveItem(at: mp4, to: destination)
        return size
    }

    private static func addSoundtrack(_ url: URL, offset: Double, videoDuration: CMTime,
                                      to timeline: AVMutableComposition, temporaryAAC: URL) async throws {
        guard offset.isFinite else { throw ExportError("Audio and camera clocks could not be aligned.") }
        let source = AVURLAsset(url: url)
        guard let pcm = try await source.loadTracks(withMediaType: .audio).first else {
            throw ExportError("The recorded soundtrack could not be read.")
        }
        let a = try await pcm.load(.timeRange)
        let delta = CMTime(seconds: offset, preferredTimescale: 48_000)
        let place = CMTimeMaximum(.zero, delta)
        let skip = CMTimeMaximum(.zero, .zero - delta)
        let overlap = CMTimeMinimum(videoDuration - place, a.duration - skip)
        guard overlap.isNumeric, overlap > .zero else { return }

        guard let encoder = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError("The soundtrack encoder is unavailable.")
        }
        encoder.timeRange = CMTimeRange(start: a.start + skip, duration: overlap)
        try await encoder.export(to: temporaryAAC, as: .m4a)
        let encoded = AVURLAsset(url: temporaryAAC)
        guard let song = try await encoded.loadTracks(withMediaType: .audio).first,
              let sound = timeline.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError("The recorded soundtrack could not be added.") }
        let range = try await song.load(.timeRange)
        let duration = CMTimeMinimum(overlap, range.duration)
        guard duration > .zero else { return }
        try sound.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: song, at: place)
    }

    private static func temporaryFile(_ ext: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
