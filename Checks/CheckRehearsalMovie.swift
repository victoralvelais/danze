import AVFoundation
import CoreImage

@main
enum CheckRehearsalMovie {
    struct MissingFrames: LocalizedError {
        let errorDescription: String? = "The simulator screen recording did not show both upright, unmirrored camera patterns."
    }

    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 192)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let context = CIContext()
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var redBlue = false, greenYellow = false
        var sampledFrames = 0
        var example: String?
        for second in stride(from: 0.0, to: duration, by: 0.2) {
            // simctl can write variable-rate video. A time during an unchanging
            // screen may have no nearby encoded frame.
            guard let result = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)) else { continue }
            let screen = CIImage(cgImage: result.image)
            guard screen.extent.height > screen.extent.width else { continue }
            sampledFrames += 1
            let width = min(screen.extent.width, screen.extent.height * 9 / 16)
            let height = width * 16 / 9
            // Coordinates are within the full, centered camera frame, measured
            // from its lower-left corner in Core Image space.
            func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                let rect = CGRect(x: floor(screen.extent.midX + (x - 0.5) * width),
                                  y: floor(screen.extent.midY + (y - 0.5) * height), width: 1, height: 1)
                var bytes = [UInt8](repeating: 0, count: 4)
                bytes.withUnsafeMutableBytes { ptr in
                    context.render(screen, toBitmap: ptr.baseAddress!, rowBytes: 4, bounds: rect, format: .RGBA8, colorSpace: rgb)
                }
                return bytes
            }
            let stripe = pixel(0.125, 0.75), right = pixel(0.875, 0.75)
            let top = pixel(0.5, 0.75), bottom = pixel(0.5, 0.25)
            if example == nil && Int(top.prefix(3).max() ?? 0) - Int(top.prefix(3).min() ?? 0) > 150 {
                example = "top \(top), bottom \(bottom), left stripe \(stripe), right \(right) at \(second) s"
            }
            guard stripe.prefix(3).allSatisfy({ $0 > 180 }), right.prefix(3).contains(where: { $0 < 95 }) else { continue }
            if top[0] > 175 && top[1] < 95 && bottom[2] > 175 && bottom[0] < 95 { redBlue = true }
            if top[1] > 175 && top[0] < 95 && bottom[0] > 175 && bottom[1] > 175 && bottom[2] < 95 { greenYellow = true }
            if redBlue && greenYellow {
                print("The simulator screen recording captured both moving portrait camera patterns and their left-side orientation mark.")
                return
            }
        }
        print("Read \(sampledFrames) portrait images from \(duration) s; red/blue=\(redBlue), green/yellow=\(greenYellow), \(example ?? "no color example").")
        throw MissingFrames()
    }
}
