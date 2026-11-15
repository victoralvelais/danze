import AVFoundation
import CoreImage
import SwiftUI

/// A normal UIKit image layer appears in the screen compositor's picture.
struct CleanCameraSurface: UIViewRepresentable {
    @ObservedObject var camera: DanceRecorder

    @MainActor final class Coordinator {
        let frames = CleanCameraFrames()
        let camera: DanceRecorder
        var display: Task<Void, Never>?
        var closed = false

        init(camera: DanceRecorder) { self.camera = camera }

        func attach() {
            Task { @MainActor [weak self] in
                guard let self, !closed else { return }
                camera.beginCleanFrames(frames)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    func makeUIView(context: Context) -> UIView {
        // A camera frame's pixel dimensions must never become the view's
        // intrinsic size in points. The parent offers the actual screen bounds.
        let view = UIView()
        view.backgroundColor = .black
        view.layer.contentsGravity = .resizeAspect
        view.isOpaque = true
        let coordinator = context.coordinator
        coordinator.display = Task { @MainActor [weak view, weak coordinator] in
            guard let frames = coordinator?.frames else { return }
            do {
                for try await image in frames.images {
                    guard !Task.isCancelled, let view else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    view.layer.contents = image
                    CATransaction.commit()
                }
            } catch {
                coordinator?.camera.cleanFramesFailed(frames, message: error.localizedDescription)
            }
        }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.attach() }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.closed = true
        coordinator.display?.cancel()
        coordinator.camera.endCleanFrames(coordinator.frames)
        view.layer.contents = nil
    }
}

final class CleanCameraFrames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let images: AsyncThrowingStream<CGImage, Error>
    private let sink: AsyncThrowingStream<CGImage, Error>.Continuation
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "dance.clean.frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private var previousPreset: AVCaptureSession.Preset?  // camera session queue
    private var lastPTS: Double?                          // frame queue
    private var lastPresented = ContinuousClock.now
    private var timer: DispatchSourceTimer?
    private var failed = false

    override init() {
        (images, sink) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    // Only the session queue touches either capture output. Both swaps commit
    // atomically; returning to studio restores the exact movie preset and codec.
    func install(on session: AVCaptureSession, movie: AVCaptureMovieFileOutput) throws {
        guard session.isRunning, !movie.isRecording, session.outputs.contains(movie) else {
            throw TakeError("The camera is unavailable. Tap to return to the controls.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        previousPreset = session.sessionPreset
        session.removeOutput(movie)
        do {
            guard session.canSetSessionPreset(.hd1280x720) else { throw TakeError("720p clean camera is unavailable.") }
            session.sessionPreset = .hd1280x720
            guard session.canAddOutput(output) else { throw TakeError("The clean camera output is unavailable.") }
            session.addOutput(output)
            output.alwaysDiscardsLateVideoFrames = true
            if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            }
            guard let connection = output.connection(with: .video), connection.isVideoOrientationSupported else {
                throw TakeError("Portrait camera output is unavailable.")
            }
            connection.setPortraitVideo(mirrored: false)
            guard !connection.isVideoMirrored else { throw TakeError("An unmirrored camera picture is unavailable.") }
            frameQueue.async {
                self.lastPresented = .now
                self.startTimer(every: .seconds(2)) { [weak self] in
                    guard let self, lastPresented.duration(to: .now) > .seconds(5) else { return }
                    fail("Camera frames stopped. Tap to return to the controls.")
                }
            }
            output.setSampleBufferDelegate(self, queue: frameQueue)
        } catch {
            try restoreOutputs(session, movie: movie)
            throw error
        }
    }

    func stop(on session: AVCaptureSession, movie: AVCaptureMovieFileOutput) throws {
        output.setSampleBufferDelegate(nil, queue: nil)
        finishRendering()
        guard previousPreset != nil else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try restoreOutputs(session, movie: movie)
    }

    func finishRendering() {
        sink.finish()
        frameQueue.async {
            self.timer?.cancel()
            self.timer = nil
            self.failed = true
        }
    }

    private func restoreOutputs(_ session: AVCaptureSession, movie: AVCaptureMovieFileOutput) throws {
        if session.outputs.contains(output) { session.removeOutput(output) }
        if !session.outputs.contains(movie) {
            guard session.canAddOutput(movie) else { throw TakeError("Reopen Dance camera to restore recording.") }
            session.addOutput(movie)
        }
        if let previousPreset {
            guard session.canSetSessionPreset(previousPreset) else { throw TakeError("Could not restore the recording resolution.") }
            session.sessionPreset = previousPreset
        }
        try DanceRecorder.configureMovieConnection(movie)
        previousPreset = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !failed, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if let lastPTS, pts >= lastPTS, pts - lastPTS < 1.0 / 30 - 0.001 { return }
        lastPTS = pts
        present(buffer)
    }

    private func present(_ buffer: CVPixelBuffer) {
        let source = CIImage(cvPixelBuffer: buffer)
        guard source.extent.height > source.extent.width,
              let image = context.createCGImage(source, from: source.extent, format: .RGBA8, colorSpace: color, deferred: false) else {
            fail("Could not render a portrait camera frame. Tap to return to the controls.")
            return
        }
        lastPresented = .now
        sink.yield(image)
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        sink.finish(throwing: TakeError(message))
    }

    private func startTimer(every interval: DispatchTimeInterval, action: @escaping () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: frameQueue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: action)
        timer = source
        source.resume()
    }

    #if targetEnvironment(simulator) && DEBUG
    static var usesSimulatorFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-clean-camera-frame-fixture")
    }

    func startSimulatorFixture() {
        frameQueue.async {
            var second = false
            let show = { [weak self] in
                guard let self else { return }
                var buffer: CVPixelBuffer?
                let size = (width: 720, height: 1280)
                guard CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                      let buffer else { self.fail("Could not create simulator camera frame."); return }
                CVPixelBufferLockBaseAddress(buffer, [])
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.stride
                for y in 0..<size.height {
                    let row = bytes.advanced(by: y * stride)
                    let color: UInt32 = y < size.height / 2 ? (second ? 0xff00ff00 : 0xffff0000)
                                                           : (second ? 0xffffff00 : 0xff0000ff)
                    row.update(repeating: color, count: size.width)
                    row.advanced(by: 72).update(repeating: 0xffffffff, count: 36)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                self.present(buffer)
                second.toggle()
            }
            show()
            self.startTimer(every: .milliseconds(500), action: show)
        }
    }
    #endif
}
