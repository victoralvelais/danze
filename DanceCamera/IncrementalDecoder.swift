import AVFoundation
import AudioToolbox

// Parse and decode only bytes the URLSession delegate has actually received.
// Native codec state survives arbitrary network packet boundaries and starvation.
final class IncrementalDecoder {
    private let output: (AVAudioPCMBuffer) throws -> Void
    private var stream: AudioFileStreamID?
    private var conversion: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var problem: Error?

    init(output: @escaping (AVAudioPCMBuffer) throws -> Void) throws {
        self.output = output
        let code = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { owner, id, property, _ in
            guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
            let decoder = Unmanaged<IncrementalDecoder>.fromOpaque(owner).takeUnretainedValue()
            do { try decoder.configure(id) } catch { decoder.problem = error }
        }, { owner, bytes, packets, data, descriptions in
            let decoder = Unmanaged<IncrementalDecoder>.fromOpaque(owner).takeUnretainedValue()
            guard decoder.problem == nil else { return }
            do { try decoder.decode(bytes: Int(bytes), packets: Int(packets), data: data, descriptions: descriptions) }
            catch { decoder.problem = error }
        }, 0, &stream)
        guard code == noErr else { throw TakeError("Could not open the audio stream parser (\(code)).") }
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    func append(_ data: Data) throws {
        guard let stream, !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = min(16384, raw.count - offset)
                let status = AudioFileStreamParseBytes(stream, UInt32(count), base.advanced(by: offset), [])
                if let problem { throw problem }
                guard status == noErr else { throw TakeError("The server returned an unsupported audio stream (\(status)).") }
                offset += count
            }
        }
    }

    private func configure(_ id: AudioFileStreamID) throws {
        guard conversion == nil else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: description))
        guard AudioFileStreamGetProperty(id, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              description.mSampleRate > 0, (1...8).contains(description.mChannelsPerFrame),
              let source = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: source.channelCount),
              let converter = AVAudioConverter(from: source, to: pcm) else {
            throw TakeError("Cannot decode this audio format. Enable MP3 transcoding in Navidrome.")
        }
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0, cookieSize <= 1024 * 1024 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw in
                AudioFileStreamGetProperty(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, raw.baseAddress!)
            }
            if status == noErr { converter.magicCookie = cookie }
        }
        inputFormat = source
        outputFormat = pcm
        conversion = converter
    }

    private func decode(bytes: Int, packets: Int, data: UnsafeRawPointer,
                        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) throws {
        guard packets > 0, bytes > 0 else { return }
        guard let inputFormat, let conversion, let outputFormat else { throw TakeError("No audio format from stream.") }
        let fixed = Int(inputFormat.streamDescription.pointee.mBytesPerPacket)
        guard descriptions != nil || (fixed > 0 && packets <= bytes / fixed) else {
            throw TakeError("Missing stream packet boundaries.")
        }
        var index = 0
        var invalid = false
        let input: AVAudioConverterInputBlock = { wanted, status in
            guard index < packets, wanted > 0 else { status.pointee = .noDataNow; return nil }
            let count = min(Int(wanted), min(32, packets - index))
            var maximum = 0
            for i in index..<(index + count) {
                let start = descriptions.map { Int($0[i].mStartOffset) } ?? i * fixed
                let size = descriptions.map { Int($0[i].mDataByteSize) } ?? fixed
                guard size > 0, size <= bytes, start >= 0, start <= bytes - size else {
                    invalid = true; status.pointee = .noDataNow; return nil
                }
                maximum = max(maximum, size)
            }
            let compressed: AVAudioCompressedBuffer
            if fixed > 0 {
                guard maximum <= fixed else { invalid = true; status.pointee = .noDataNow; return nil }
                compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: UInt32(count))
            } else {
                compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: UInt32(count), maximumPacketSize: maximum)
            }
            var offset = 0
            for n in 0..<count {
                let i = index + n
                let size = descriptions.map { Int($0[i].mDataByteSize) } ?? fixed
                let start = descriptions.map { Int($0[i].mStartOffset) } ?? i * fixed
                compressed.data.advanced(by: offset).copyMemory(from: data.advanced(by: start), byteCount: size)
                compressed.packetDescriptions?[n] = AudioStreamPacketDescription(
                    mStartOffset: Int64(offset), mVariableFramesInPacket: descriptions?[i].mVariableFramesInPacket ?? 0,
                    mDataByteSize: UInt32(size))
                offset += size
            }
            compressed.packetCount = UInt32(count)
            compressed.byteLength = UInt32(offset)
            index += count
            status.pointee = .haveData
            return compressed
        }
        try convert(conversion, format: outputFormat, input: input)
        guard !invalid, index == packets else { throw TakeError("Corrupt or incomplete audio packets.") }
    }

    func finish() throws {
        if let conversion, let outputFormat {
            try convert(conversion, format: outputFormat) { _, status in status.pointee = .endOfStream; return nil }
        }
    }

    private func convert(_ converter: AVAudioConverter, format: AVAudioFormat, input: @escaping AVAudioConverterInputBlock) throws {
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw TakeError("Could not allocate decoder output.") }
            var error: NSError?
            let result = converter.convert(to: pcm, error: &error, withInputFrom: input)
            if result == .error { throw error ?? TakeError("Failed to decode the streamed audio.") }
            if pcm.frameLength > 0 { try output(pcm) }
            if result != .haveData || pcm.frameLength == 0 { return }
        }
    }
}
