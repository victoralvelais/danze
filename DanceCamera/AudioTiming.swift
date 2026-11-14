import Foundation

// Within a running mixer graph the sample clock identifies exactly adjacent buffers.
// The first presentation timestamp anchors that clock to the camera clock.
struct MixerTimeline {
    private var baseSample: Int64?
    private var baseHost = 0.0
    private var expected: Int64?
    private var nextHost: Double?

    mutating func position(sample: Int64?, host: Double, count: Int, rate: Double) -> Double {
        let point: Double
        if let sample {
            if baseSample == nil || expected.map({ sample < $0 - Int64(count) }) == true {
                baseSample = sample
                baseHost = nextHost.map { max($0, host) } ?? host
            }
            point = baseHost + Double(sample - (baseSample ?? sample)) / rate
            expected = sample + Int64(count)
        } else {
            point = nextHost ?? host
            if let expected { self.expected = expected + Int64(count) }
        }
        nextHost = point + Double(count) / rate
        return point
    }
}

struct SpeedChange {
    let host: Double
    let rate: Double
}

struct TakeSpeedRange {
    let start: Double
    let end: Double
    let rate: Double

    static func ranges(changes: [SpeedChange], videoStart: Double, duration: Double) -> [Self] {
        var start = 0.0, rate = 1.0, result: [Self] = []
        for change in changes.sorted(by: { $0.host < $1.host }) {
            let time = min(duration, max(0, change.host - videoStart))
            if time > start { result.append(Self(start: start, end: time, rate: rate)) }
            start = time
            rate = change.rate
        }
        if duration > start { result.append(Self(start: start, end: duration, rate: rate)) }
        return result
    }
}
