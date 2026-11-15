import AVFoundation

// Verify a single constant-rate transport against music actually heard in the mixer.
// Times returned here are offsets in the decoded CAF, in original-song seconds.
enum SoundtrackAlignment {
    private typealias Bands = SIMD3<Double>
    private static let hop = 0.005
    private static let weights = (-10...10).map { exp(-0.5 * pow(Double($0) / 2.5, 2)) }
    private static let weightSum = weights.reduce(0, +)

    static func offset(source: URL, mix: URL, mixStart: Double, duration: Double, rate: Double) throws -> Double? {
        guard (0.5...2).contains(rate), duration >= 2, duration.isFinite, mixStart.isFinite else { return nil }
        let song = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let live = try AVAudioFile(forReading: mix, commonFormat: .pcmFormatFloat32, interleaved: false)
        let slack = Double(song.length) / song.processingFormat.sampleRate - duration * rate
        // Search every feasible offset or decline; a repeated passage outside a truncated
        // search could otherwise win by default. Capture already limits decoder pre-roll.
        guard slack >= 0, slack <= 15, mixStart >= 0,
              mixStart + duration <= Double(live.length + 1) / live.processingFormat.sampleRate else { return nil }
        let shifts = Int(floor(slack / hop)) + 1
        let windows = min(9, max(3, Int(min(duration, 24) / 2.5) + 1))
        let bins = Int(min(1.2, (duration - 0.10) / Double(windows)) / hop)
        // Exact length after rounding bin centers during speed conversion, plus interpolation.
        let lastBin = Int(ceil((Double(bins - 1) + 0.5) * rate - 0.5))
        var scores = [[Double]]()
        for i in 0..<windows {
            let position = 0.05 + (duration - 0.10 - Double(bins) * hop) * Double(i) / Double(windows - 1)
            guard let query = try envelope(live, at: mixStart + position, count: bins),
                  let reference = try envelope(song, at: position * rate, count: shifts + lastBin + 1)
            else { return nil }
            scores.append(correlations(query, reference: reference, shifts: shifts, rate: rate))
        }
        let mean = (0..<shifts).map { j in scores.reduce(0.0) { $0 + $1[j] } / Double(windows) }
        guard let best = mean.indices.max(by: { mean[$0] < mean[$1] }), mean[best] >= 0.80 else { return nil }
        let neighborhood = max(2, Int(ceil(0.075 * rate / hop)))
        for i in mean.indices where abs(i - best) > neighborhood && mean[i] >= mean[best] - 0.065 { return nil }
        var offsets = [Double]()
        for window in scores {
            let local = max(0, best - neighborhood)...min(shifts - 1, best + neighborhood)
            guard let peak = local.max(by: { window[$0] < window[$1] }),
                  window[peak] >= 0.68, (window.max() ?? -1) <= window[peak] + 0.06 else { return nil }
            var fraction = 0.0
            if peak > 0, peak + 1 < shifts {
                let curvature = 2 * window[peak] - window[peak - 1] - window[peak + 1]
                if curvature > 0.0001 {
                    fraction = min(0.5, max(-0.5, (window[peak + 1] - window[peak - 1]) / (2 * curvature)))
                }
            }
            offsets.append((Double(peak) + fraction) * hop)
        }
        let center = offsets.sorted()[windows / 2]
        // Centering bounds error at both ends. The half-bin allowance is measurement
        // uncertainty; the remaining bound is half a 30 fps frame in camera time.
        guard offsets.allSatisfy({ abs($0 - center) <= rate / 60 + hop / 2 }),
              center >= 0, center <= slack else { return nil }
        return center
    }

    // Three band energies measure changes in the music while ignoring stereo phase,
    // gain and the pitch-preserving rate change. Read only a bounded window in blocks.
    private static func envelope(_ file: AVAudioFile, at start: Double, count: Int) throws -> [Bands]? {
        let format = file.processingFormat, hz = format.sampleRate, channels = Int(format.channelCount)
        guard (8000...192000).contains(hz), (1...8).contains(channels), count > 0 else { return nil }
        let first = Int64((start * hz).rounded())
        let total = Int((Double(count) * hop * hz).rounded())
        guard first >= 0, first + Int64(total) <= file.length,
              let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
        file.framePosition = first
        var low = Array(repeating: 0.0, count: channels), mid = low
        let a = 1 - exp(-2 * Double.pi * 260 / hz), b = 1 - exp(-2 * Double.pi * 2300 / hz)
        var result = [Bands](), sum = Bands.zero, processed = 0, binStart = 0
        result.reserveCapacity(count)
        while processed < total {
            try file.read(into: block, frameCount: UInt32(min(4096, total - processed)))
            guard let samples = block.floatChannelData, block.frameLength > 0 else { return nil }
            var offset = 0
            while offset < Int(block.frameLength) {
                let binEnd = Int((Double(result.count + 1) * hop * hz).rounded())
                let length = min(binEnd - processed, Int(block.frameLength) - offset)
                for ch in 0..<channels {
                    var l = low[ch], m = mid[ch]
                    for j in offset..<(offset + length) {
                        let x = Double(samples[ch][j])
                        l += a * (x - l)
                        m += b * (x - m)
                        let values = Bands(l, m - l, x - m)
                        sum += values * values
                    }
                    low[ch] = l; mid[ch] = m
                }
                processed += length; offset += length
                if processed == binEnd {
                    let energy = sum / Double((binEnd - binStart) * channels)
                    result.append(energy)
                    binStart = binEnd; sum = .zero
                }
            }
        }
        // Integrate power before taking logs. A 10–15 ms interruption should not
        // overwhelm the energy and timing of the surrounding musical onset.
        return result.indices.map { i in
            var energy = Bands.zero
            for j in weights.indices {
                energy += result[min(result.count - 1, max(0, i + j - 10))] * weights[j]
            }
            energy /= weightSum
            return Bands(log(max(1e-9, energy.x)), log(max(1e-9, energy.y)), log(max(1e-9, energy.z)))
        }
    }

    private static func correlations(_ query: [Bands], reference: [Bands], shifts: Int, rate: Double) -> [Double] {
        // Omit filter startup from each independent window.
        let count = Double(query.count - 5)
        let mean = query.dropFirst(5).reduce(Bands.zero, +) / count
        let centered = query.dropFirst(5).map { $0 - mean }
        let variance = centered.reduce(Bands.zero) { $0 + $1 * $1 }
        let positions = (5..<query.count).map { i -> (Int, Double) in
            let t = (Double(i) + 0.5) * rate - 0.5
            return (Int(floor(t)), t - floor(t))
        }
        return (0..<shifts).map { shift in
            var total = Bands.zero, squares = Bands.zero, cross = Bands.zero
            for j in centered.indices {
                let (index, weight) = positions[j]
                let left = reference[shift + index]
                let value = left + (reference[shift + index + 1] - left) * weight
                total += value; squares += value * value; cross += centered[j] * value
            }
            let power = squares - total * total / count
            var score = 0.0, bands = 0
            for ch in 0..<3 where min(power[ch], variance[ch]) > 0.04 * count {
                score += cross[ch] / sqrt(power[ch] * variance[ch])
                bands += 1
            }
            return bands >= 2 ? score / Double(bands) : -1
        }
    }
}
