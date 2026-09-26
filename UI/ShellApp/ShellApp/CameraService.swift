import AVFoundation
import SwiftUI

/// Just the rear camera preview. No frame processing yet.
final class CameraService: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "shellapp.camera")

    /// Returns false if permission is denied or there is no camera (e.g. the simulator).
    func start() async -> Bool {
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.session.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          let input = try? AVCaptureDeviceInput(device: device),
                          self.session.canAddInput(input) else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.session.addInput(input)
                }
                self.session.startRunning()
                continuation.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
