import ARKit
import SwiftUI

/// The app's one ARKit session: the rear camera feed on `CameraScreen`, and world tracking for
/// `PositionTracker`. Owned by `AppModel` so the camera screen and navigation share it.
@MainActor
@Observable
final class CameraService {
    @ObservationIgnored let session = ARSession()
    private(set) var isRunning = false

    /// Returns false if permission is denied or the device can't run ARKit (e.g. the simulator).
    /// Does nothing if it's already running, so tracking isn't reset mid-walk.
    func start() async -> Bool {
        if isRunning { return true }
        guard ARWorldTrackingConfiguration.isSupported,
              await AVCaptureDevice.requestAccess(for: .video) else { return false }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
