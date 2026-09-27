import ARKit

/// Where the phone is, from ARKit world tracking: meters seen from above, x to the right and y
/// forward (ARKit's -z), the same way round as the map. It starts wherever tracking started and is
/// turned from the map by an unknown angle, which `RouteNavigator` learns as the user walks.
@MainActor
final class PositionTracker: NSObject {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var onPosition: ((SIMD2<Double>) -> Void)?
    /// Nil while tracking is good; otherwise why it isn't.
    var onStatus: ((String?) -> Void)?

    /// Positions are passed on this often. Walking covers about 15 cm in that time.
    private static let interval: TimeInterval = 0.1

    private let session: ARSession
    private var lastSample: TimeInterval = 0
    private var status: String?

    /// `session` is `AppModel`'s; running and pausing it is up to `CameraService`.
    init(session: ARSession) {
        self.session = session
    }

    func start() {
        session.delegate = self
    }

    func stop() {
        if session.delegate === self { session.delegate = nil }
    }

    private func report(_ status: String?) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }
}

extension PositionTracker: ARSessionDelegate {
    // ARKit calls these on the main queue, since no delegate queue is set.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Only copy values out: holding on to the frame stalls the camera.
        let time = frame.timestamp
        let state = frame.camera.trackingState
        let column = frame.camera.transform.columns.3
        let position = SIMD2(Double(column.x), Double(-column.z))
        MainActor.assumeIsolated {
            switch state {
            case .normal:
                report(nil)
                guard time - lastSample >= Self.interval else { return }
                lastSample = time
                onPosition?(position)
            case .limited(.initializing), .limited(.relocalizing):
                report("Finding its bearings…")
            case .limited(.excessiveMotion):
                report("Moving too fast to track")
            case .limited(.insufficientFeatures):
                report("Can't see enough to track")
            case .limited:
                report("Tracking is limited")
            case .notAvailable:
                report("Tracking isn't available")
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { report("Tracking paused: the camera is in use") }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { report("Tracking stopped: \(message)") }
    }
}
