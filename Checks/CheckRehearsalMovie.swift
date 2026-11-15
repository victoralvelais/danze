import AVFoundation

@main
enum CheckRehearsalMovie {
    struct Pixel: CustomStringConvertible {
        let r: UInt8, g: UInt8, b: UInt8
        var red: Bool { r > 175 && g < 95 && b < 95 }
        var blue: Bool { b > 175 && r < 95 && g < 95 }
        var green: Bool { g > 175 && r < 95 && b < 95 }
        var yellow: Bool { r > 175 && g > 175 && b < 95 }
        var white: Bool { min(r, g, b) > 180 }
        var description: String { "(\(r),\(g),\(b))" }
    }

    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { exit(1) }
        let transform = try await track.load(.preferredTransform)
        let inverse = transform.inverted()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var redBlue = false, greenYellow = false, count = 0
        var lastPattern = ""
        while let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) {
            count += 1
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            guard let bytes = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
            let screen = CGRect(x: 0, y: 0, width: w, height: h).applying(transform).standardized
            guard screen.height > screen.width else { continue }
            let width = min(screen.width, screen.height * 9 / 16)
            let height = width * 16 / 9
            // AVFoundation's track transform maps the native pixels to display coordinates.
            // Sample the original screen recording in top-left coordinates, without rescaling.
            func pixel(_ x: CGFloat, _ y: CGFloat) -> Pixel {
                let display = CGPoint(x: screen.midX + (x - 0.5) * width, y: screen.midY + (y - 0.5) * height)
                let p = display.applying(inverse)
                let row = max(0, min(h - 1, Int(p.y))) * CVPixelBufferGetBytesPerRow(frame)
                let i = row + max(0, min(w - 1, Int(p.x))) * 4
                return Pixel(r: bytes[i+2], g: bytes[i+1], b: bytes[i])
            }
            let top = pixel(0.5, 0.25), bottom = pixel(0.5, 0.75)
            let left = pixel(0.125, 0.25), right = pixel(0.875, 0.25)
            if top.red || top.green || bottom.blue || bottom.yellow {
                lastPattern = "top \(top), bottom \(bottom), left mark \(left), right \(right), time \(sample.presentationTimeStamp.seconds)"
            }
            guard left.white && !right.white else { continue }
            redBlue = redBlue || (top.red && bottom.blue)
            greenYellow = greenYellow || (top.green && bottom.yellow)
            if redBlue && greenYellow {
                print("The simulator screen recording captured both moving portrait camera patterns and their left-side orientation mark.")
                return
            }
        }
        let details = "Read \(count) screen frames. Red/blue=\(redBlue), green/yellow=\(greenYellow). Last candidate: \(lastPattern). Reader: \(reader.status.rawValue)."
        FileHandle.standardError.write(Data(("::error::Rehearsal movie missing expected camera picture. " + details + "\n").utf8))
        exit(1)
    }
}
