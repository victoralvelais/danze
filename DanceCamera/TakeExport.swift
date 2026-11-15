import AVFoundation
import OSLog

struct TakeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum TakeExport {
    private static let log = Logger(subsystem: "dev.codexxp.dancecamera", category: "soundtrack")
    enum AudioPath: Equatable {
        case none, source, matchedSource, mix(SourceFallback)
        var description: String {
            switch self {
            case .none: return "Camera video without a soundtrack."
            case .source: return "Decoded song audio. Verified by player timing."
            case .matchedSource: return "Decoded song audio. Verified against the recorded music."
            case .mix(let reason): return "Captured mixer audio. " + reason.rawValue
            }
        }
    }
    struct Result {
        let size: CGSize
        let audioPath: AudioPath
        let recordedRates: [Double]
    }
    struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // The offset is signed: the tap can already be playing when the camera starts.
    static func save(video: URL, audio: URL?, audioOffset: Double, speeds: [SpeedChange] = [], restoreTempo: Bool = true, videoStart: Double = 0,
                     source: SourceSoundtrack? = nil, sourceFallback: SourceFallback = .noAnchor,
                     appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                     to destination: URL) async throws -> Result {
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
        let captured = TakeSpeedRange.ranges(changes: speeds, videoStart: videoStart, duration: v.duration.seconds)
        let ranges = restoreTempo ? captured : []
        let scaled = ranges.contains { abs($0.rate - 1) > 0.0001 }
        let rendered = temporaryFile("caf")
        defer { try? FileManager.default.removeItem(at: rendered) }
        if scaled { retime(picture, using: ranges) }
        var audioPath = AudioPath.none
        if let audio {
            var fallback = source == nil ? sourceFallback : .alignment
            var sourceStart = source?.offset(videoStart: videoStart, duration: v.duration.seconds)
            var sourcePath = AudioPath.source
            if let source, sourceStart == nil, source.coversStableTransport(videoStart: videoStart, duration: v.duration.seconds),
               captured.allSatisfy({ abs($0.rate - source.rate) < 0.0001 }) {
                sourceStart = try? SoundtrackAlignment.offset(source: source.file.url, mix: audio, mixStart: -audioOffset,
                                                             duration: v.duration.seconds, rate: source.rate)
                sourcePath = .matchedSource
            }
            if let source, let start = sourceStart,
               !scaled || ranges.allSatisfy({ abs($0.rate - source.rate) < 0.0001 }) {
                do {
                    var url = source.file.url, offset = -start
                    if !scaled && source.rate != 1 {
                        let range = TakeSpeedRange(start: 0, end: v.duration.seconds * source.rate, rate: 1 / source.rate)
                        try renderAudio(url, offset: offset, ranges: [range], to: rendered)
                        url = rendered
                        offset = 0
                    }
                    guard try await addSoundtrack(url, offset: offset, videoDuration: picture.timeRange.duration,
                                                  to: timeline, temporaryAAC: aac) else {
                        throw ExportError("The source recording does not span the take.")
                    }
                    audioPath = sourcePath
                } catch {
                    for track in timeline.tracks(withMediaType: .audio) { timeline.removeTrack(track) }
                    try? FileManager.default.removeItem(at: aac)
                    try? FileManager.default.removeItem(at: rendered)
                    fallback = .render
                }
            }
            if audioPath == .none {
                let added: Bool
                if scaled {
                    try renderAudio(audio, offset: audioOffset, ranges: ranges, to: rendered)
                    added = try await addSoundtrack(rendered, offset: 0, videoDuration: picture.timeRange.duration, to: timeline, temporaryAAC: aac)
                } else {
                    added = try await addSoundtrack(audio, offset: audioOffset, videoDuration: v.duration, to: timeline, temporaryAAC: aac)
                }
                if added { audioPath = .mix(fallback) }
            }
        }
        guard let mux = AVAssetExportSession(asset: timeline, presetName: AVAssetExportPresetPassthrough),
              mux.supportedFileTypes.contains(.mp4) else { throw ExportError("The camera format could not be packaged as MP4.") }
        let note = AVMutableMetadataItem()
        // MP4 clip metadata uses the 3GPP user-data description ('dscp') and language.
        note.identifier = .identifier3GPUserDataDescription
        note.extendedLanguageTag = "en"
        let app = ["Dance Camera", appVersion].compactMap { $0 }.joined(separator: " ")
        note.value = (app + ". " + audioPath.description) as NSString
        note.dataType = kCMMetadataBaseDataType_UTF8 as String
        mux.metadata = (mux.metadata ?? []) + [note]
        try await mux.export(to: mp4, as: .mp4)
        try FileManager.default.moveItem(at: mp4, to: destination)
        log.info("\(audioPath.description, privacy: .public)")
        let rates = speeds.isEmpty ? [] : Set(captured.map(\.rate)).sorted()
        return Result(size: size, audioPath: audioPath, recordedRates: rates)
    }

    @discardableResult
    private static func addSoundtrack(_ url: URL, offset: Double, videoDuration: CMTime,
                                      to timeline: AVMutableComposition, temporaryAAC: URL) async throws -> Bool {
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
        guard overlap.isNumeric, overlap > .zero else { return false }

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
        guard duration > .zero else { return false }
        try sound.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: song, at: place)
        return true
    }

    private static func retime(_ track: AVMutableCompositionTrack, using ranges: [TakeSpeedRange]) {
        for segment in ranges.reversed() where abs(segment.rate - 1) > 0.0001 {
            let start = CMTime(seconds: segment.start, preferredTimescale: 60_000)
            let end = CMTime(seconds: segment.end, preferredTimescale: 60_000)
            let range = CMTimeRange(start: start, end: end)
            if range.duration > .zero {
                track.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: segment.rate))
            }
        }
    }

    // Render an exact number of output frames for every live speed interval.
    // The offline graph can read ahead around a boundary without dropping output duration.
    private static func renderAudio(_ url: URL, offset: Double, ranges: [TakeSpeedRange], to target: URL) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat, hz = format.sampleRate
        let output = try AVAudioFile(forWriting: target, settings: format.settings)
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw ExportError("Audio allocation failed.") }
        var accumulated = 0.0
        for range in ranges {
            let outputStart = Int64((accumulated * hz).rounded())
            accumulated += (range.end - range.start) * range.rate
            let needed = Int64((accumulated * hz).rounded()) - outputStart
            guard needed > 0 else { continue }
            let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
            engine.attach(player); engine.attach(pitch)
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            pitch.rate = Float(1 / range.rate)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
            defer { engine.stop() }
            let first = Int64(((range.start - offset) * hz).rounded())
            let warmup = Int64((0.10 * hz).rounded())
            let readStart = min(input.length, max(0, first - warmup))
            let skip = Int64((Double(max(0, first - readStart)) * range.rate).rounded())
            let leading = min(needed, Int64((Double(max(0, -first)) * range.rate).rounded()))
            var zeros = leading
            while zeros > 0 {
                block.frameLength = UInt32(min(4096, zeros))
                for ch in 0..<Int(format.channelCount) {
                    memset(block.floatChannelData![ch], 0, Int(block.frameLength) * MemoryLayout<Float>.size)
                }
                try output.write(from: block)
                zeros -= Int64(block.frameLength)
            }
            let available = max(0, min(input.length - readStart, Int64(((range.end - offset) * hz).rounded()) - readStart + warmup))
            if available > 0 {
                player.scheduleSegment(input, startingFrame: readStart, frameCount: UInt32(clamping: available), at: nil)
            }
            player.play()
            var discard = skip, remaining = needed - leading, retries = 0
            while remaining > 0 {
                let want = UInt32(min(4096, discard > 0 ? discard : remaining))
                let status = try engine.renderOffline(want, to: block)
                if status == .cannotDoInCurrentContext && retries < 32 { retries += 1; continue }
                guard status == .success, block.frameLength > 0 else { throw ExportError("Could not render tempo-adjusted audio.") }
                retries = 0
                if discard > 0 { discard -= Int64(block.frameLength) }
                else { try output.write(from: block); remaining -= Int64(block.frameLength) }
            }
        }
    }

    private static func temporaryFile(_ ext: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
