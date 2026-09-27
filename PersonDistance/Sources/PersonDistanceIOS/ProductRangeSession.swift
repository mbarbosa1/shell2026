#if os(iOS)
import ARKit
import Observation

/// How far the product the shopper said Yes to is from the phone's camera, for as long as it
/// stays in view. The one thing apps use from this package.
///
/// 1. `follow(_:box:imageSize:)` when recognition confirms an item and asks "Is this …?": the
///    product is tracked so its box is current, but nothing is measured and LiDAR stays off.
/// 2. `measure(_:)` when the shopper says Yes: LiDAR goes on and `sample` updates.
/// 3. `stop()` on No, and when shopping ends. Losing the product stops it too (`status == .lost`).
///
/// Display-only for now: nothing is spoken, sent to the watch, or decided from it (README).
@MainActor
@Observable
public final class ProductRangeSession {
    public enum Status: Equatable, Sendable {
        case idle
        /// Recognition confirmed the item and is asking the shopper. Tracked, not measured.
        case following
        /// The shopper said Yes. `sample` is the latest valid reading, if any.
        case measuring
        /// The product left the view or couldn't be told apart any more.
        case lost
        /// This phone has no LiDAR, so there is no distance to give.
        case noDepth
    }

    public private(set) var status = Status.idle
    /// The latest reading `policy` accepted, from this frame or a recent one. Nil otherwise:
    /// better no distance than a wrong one.
    public private(set) var sample: DistanceSample?
    /// Why the latest reading wasn't used, for testers. Nil after a valid one.
    public private(set) var rejection: SpatialValidityPolicy.Rejection?
    /// The item being followed or measured.
    public var item: UUID? { gate.item }

    @ObservationIgnored public var policy: SpatialValidityPolicy
    @ObservationIgnored private let session: ARSession
    @ObservationIgnored private var gate = MeasurementGate()
    @ObservationIgnored private var tracker: ConfirmedProductTracker?
    @ObservationIgnored private var checks: Task<Void, Never>?
    /// Frame time the product was last found at, for `lostAfter`.
    @ObservationIgnored private var lastFound: TimeInterval?
    /// True while this session has LiDAR turned on, so `stop()` turns off only what it turned on.
    @ObservationIgnored private var depthOn = false
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "persondistance.range")

    /// How often the newest frame is checked. Tracking and depth take a few ms each.
    private static let checkInterval: Duration = .milliseconds(100)
    /// Seconds without finding the product before it counts as lost.
    private static let lostAfter: TimeInterval = 1

    /// `session` is the app's one ARKit session; this reads its frames, and adds LiDAR depth to
    /// its configuration only while measuring.
    public init(session: ARSession, policy: SpatialValidityPolicy = SpatialValidityPolicy()) {
        self.session = session
        self.policy = policy
    }

    /// Recognition confirmed `item` and is asking the shopper about it. Starts following the
    /// product; a repeat for the same item does nothing.
    /// - Parameters:
    ///   - box: the one product recognition matched, in pixels of ARKit's landscape image from
    ///     its top left. Never a region around several products.
    ///   - imageSize: that image's size.
    public func follow(_ item: UUID, box: CGRect, imageSize: CGSize) {
        guard gate.confirmed(item) else { return }
        stopChecks()
        setDepth(false)
        tracker = ConfirmedProductTracker(box: box, imageSize: imageSize)
        lastFound = nil
        status = .following
        startChecks()
    }

    /// The shopper said Yes to `item`. Starts measuring if that's the item being followed.
    public func measure(_ item: UUID) {
        guard gate.accepted(item) else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            stop()
            status = .noDepth
            return
        }
        setDepth(true)
        status = .measuring
    }

    /// Stops following or measuring and turns LiDAR back off. Call before pausing the session.
    public func stop() {
        gate.reset()
        stopChecks()
        setDepth(false)
        status = .idle
    }

    // MARK: Private

    private func startChecks() {
        checks = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func stopChecks() {
        checks?.cancel()
        checks = nil
        tracker = nil
        sample = nil
        rejection = nil
    }

    /// Tracks the product in the newest frame and, once measuring, reads its depth in that same frame.
    private func check() async {
        guard let tracker, let frame = session.currentFrame.map(DepthFrame.init) else { return }
        let measuring = gate.isMeasuring
        let result: (box: CGRect?, sample: DistanceSample?) = await withCheckedContinuation { done in
            visionQueue.async {
                let box = tracker.track(in: frame.image, imageSize: frame.imageSize)
                done.resume(returning: (box, measuring ? box.flatMap { ProductDepthEstimator.sample(of: $0, in: frame) } : nil))
            }
        }
        guard !Task.isCancelled, self.tracker === tracker else { return }

        // The first check counts as a sighting: the confirmed box is from a moment ago.
        let seen = result.box == nil ? (lastFound ?? frame.time) : frame.time
        lastFound = seen
        if frame.time - seen > Self.lostAfter {
            lose()
            return
        }
        guard gate.isMeasuring else { return }
        let now = session.currentFrame?.timestamp ?? frame.time
        if let reading = result.sample {
            rejection = policy.rejection(of: reading, now: now)
            if rejection == nil { sample = reading }
        }
        if let sample, now - sample.frameTime > policy.maximumAge { self.sample = nil }
    }

    private func lose() {
        gate.reset()
        stopChecks()
        setDepth(false)
        status = .lost
    }

    /// Adds or removes LiDAR scene depth by re-running the session's own configuration without
    /// reset options, so world tracking and anchors carry on (README step 6).
    private func setDepth(_ on: Bool) {
        guard on != depthOn,
              let configuration = session.configuration as? ARWorldTrackingConfiguration else { return }
        if on {
            guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { return }
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            configuration.frameSemantics.remove(.sceneDepth)
        }
        session.run(configuration)
        depthOn = on
    }
}
#endif
