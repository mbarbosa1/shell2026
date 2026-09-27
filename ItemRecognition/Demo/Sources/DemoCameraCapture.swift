import AVFoundation
import Foundation
import ItemRecognition

/// Owns this standalone demo's only camera session. The library owns no camera.
/// Session configuration and mutable capture state are confined to `queue`.
/// Only the preview layer receives the session on the main thread. Each submitted
/// pixel buffer is retained and never mutated while the recognition task uses it.
final class DemoCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case started
        case update(RecognitionUpdate, Double)
        case failure(String)
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ItemRecognitionDemo.camera", qos: .userInitiated)
    private let receive: @Sendable (Event) -> Void
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var scanning = false
    private var processing = false
    private var runID: UInt = 0
    private var coordinator: RecognitionCoordinator?
    private var context: RecognitionContext?

    init(receive: @escaping @Sendable (Event) -> Void) {
        self.receive = receive
        super.init()
    }

    func start(coordinator: RecognitionCoordinator, context: RecognitionContext) {
        queue.async { [self] in
            guard !scanning else { return }
            do {
                try configureIfNeeded()
                runID &+= 1
                self.coordinator = coordinator
                self.context = context
                scanning = true
                session.startRunning() // Intentionally off the main thread.
                guard session.isRunning else { throw CameraError.couldNotStart }
                receive(.started)
            } catch {
                scanning = false
                receive(.failure(error.localizedDescription))
            }
        }
    }

    /// Replaces the landmark progress sent with the next frame. The gate re-evaluates it
    /// there, so calibration changes apply without restarting the camera.
    func update(context: RecognitionContext) {
        queue.async { [self] in
            guard scanning else { return }
            self.context = context
        }
    }

    func acceptInsight() {
        queue.async { [self] in
            guard let coordinator else { return }
            Task { await coordinator.acceptInsight() }
        }
    }

    func rejectInsight() {
        queue.async { [self] in
            guard let coordinator else { return }
            Task { await coordinator.rejectInsight() }
        }
    }

    func stop() {
        queue.async { [self] in
            scanning = false
            runID &+= 1
            if let coordinator { Task { await coordinator.stop() } }
            coordinator = nil
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noRearCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080
        guard session.canAddInput(input) else { throw CameraError.configuration }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.configuration
        }
        session.addOutput(output)
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
            session.removeOutput(output)
            session.removeInput(input)
            throw CameraError.orientation
        }
        // Physically rotate captured buffers upright; RecognitionImage must then use .up.
        // The app and preview are locked to portrait to keep this demo simple.
        connection.videoRotationAngle = 90
        output.setSampleBufferDelegate(self, queue: queue)
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard scanning, !processing, let coordinator, let suppliedContext = context,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processing = true
        let currentRun = runID
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let image = RecognitionImage(timestamp: timestamp, pixelBuffer: buffer,
            imageResolution: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            orientation: .up)
        let context = RecognitionContext(targetItemID: suppliedContext.targetItemID,
            landmarkProgress: LandmarkProgressObservation(timestamp: timestamp,
                passedLandmarkID: suppliedContext.landmarkProgress.passedLandmarkID,
                metersPastLandmark: suppliedContext.landmarkProgress.metersPastLandmark,
                isReliable: suppliedContext.landmarkProgress.isReliable),
            externalPause: suppliedContext.externalPause)

        // At most one asynchronous submission exists. New camera frames are dropped
        // while it runs, preventing a camera-rate backlog of tasks or retained buffers.
        Task { [self] in
            let started = Date()
            let event: Event?
            do {
                let update = try await coordinator.submit(context, image: image)
                event = update.result != nil ? .update(update, Date().timeIntervalSince(started) * 1000) : nil
            } catch {
                event = .failure("Recognition failed: \(error.localizedDescription). Tap Start camera to retry.")
            }
            queue.async { [self] in
                processing = false
                guard scanning, runID == currentRun, let event else { return }
                if case .failure = event {
                    scanning = false
                    session.stopRunning()
                }
                receive(event)
            }
        }
    }

    private enum CameraError: LocalizedError {
        case noRearCamera, configuration, orientation, couldNotStart
        var errorDescription: String? {
            switch self {
            case .noRearCamera: return "No rear camera found. Run this app on a physical iPhone."
            case .configuration: return "Could not configure the camera. Stop other camera apps and try again."
            case .orientation: return "This camera cannot supply the portrait frames required by the demo."
            case .couldNotStart: return "The camera did not start. Check camera access and try again."
            }
        }
    }
}
