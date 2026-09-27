#if os(iOS)
import ARKit
import Observation

/// How far the product the shopper said Yes to is from the phone's camera, and then how far their
/// fingertip is from it (the user distance). The one thing apps use from this package; there is
/// one per app, and pickup and the self-checkout finder never use it at the same time.
///
/// 1. `follow(_:box:imageSize:)` when recognition confirms an item and asks "Is this …?": the
///    product is tracked so its box is current, but nothing is measured and LiDAR stays off.
/// 2. `measure(_:)` when the shopper says Yes: LiDAR goes on, and `sample` and `box` update.
///    (`measureNow(_:box:imageSize:)` does 1 and 2 at once, for the self-checkout, which has no Yes.)
/// 3. `anchorProduct()` once the arm has centered on it: its place in the world is kept and
///    tracking stops, since the shopper's hand is about to cover it.
/// 4. `handSample(at:in:)` for each hand check: the fingertip against that place.
/// 5. `stop()` on No, when pickup ends, and when shopping ends. Losing the product before step 3
///    stops it too (`status == .lost`).
@MainActor
@Observable
public final class ProductRangeSession {
    public enum Status: Equatable, Sendable {
        case idle
        /// Recognition confirmed the item and is asking the shopper. Tracked, not measured.
        case following
        /// The shopper said Yes. `sample` is the latest valid reading, if any.
        case measuring
        /// The product's place is kept (`anchor`) for hand guiding; it's no longer tracked.
        case anchored
        /// The product left the view or couldn't be told apart any more.
        case lost
        /// This phone has no LiDAR, so there is no distance to give.
        case noDepth
    }

    /// Where a product was when `anchorProduct()` kept it.
    public struct Anchor: Equatable, Sendable {
        /// The middle of the product's box, on its surface, in ARKit's world frame (meters).
        public let worldPoint: SIMD3<Float>
        /// The product's box then, in the camera image's pixels, and that image's size.
        public let box: CGRect
        public let imageSize: CGSize
    }

    public private(set) var status = Status.idle
    /// The latest reading `policy` accepted, from this frame or a recent one. Nil otherwise:
    /// better no distance than a wrong one.
    public private(set) var sample: DistanceSample?
    /// Why the latest reading wasn't used, for testers. Nil after a valid one.
    public private(set) var rejection: SpatialValidityPolicy.Rejection?
    /// Where the followed product is in the newest checked frame (camera image pixels, top left),
    /// and that image's size. Nil when not following or measuring.
    public private(set) var box: CGRect?
    public private(set) var imageSize: CGSize?
    public private(set) var anchor: Anchor?
    /// The latest fingertip reading while anchored.
    public private(set) var hand: HandSample?
    /// The item being followed or measured.
    public var item: UUID? { gate.item }

    @ObservationIgnored public var policy: SpatialValidityPolicy
    @ObservationIgnored private let session: ARSession
    @ObservationIgnored private var gate = MeasurementGate()
    @ObservationIgnored private var tracker: ConfirmedProductTracker?
    @ObservationIgnored private var checks: Task<Void, Never>?
    /// Frame time the product was last found at, for `lostAfter`.
    @ObservationIgnored private var lastFound: TimeInterval?
    /// World point of the latest valid reading, for `anchorProduct()`.
    @ObservationIgnored private var lastWorldPoint: SIMD3<Float>?
    /// True while this session has LiDAR turned on, so `stop()` turns off only what it turned on.
    @ObservationIgnored private var depthOn = false
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "persondistance.range")

    /// How often the newest frame is checked: 20 a second, like the tracker the arm was first tuned
    /// with (ShellApp's former `ProductTracker`). Tracking and depth take a few ms each.
    private static let checkInterval: Duration = .milliseconds(50)
    /// Seconds without finding the product before it counts as lost (also as first tuned).
    static let lostAfter: TimeInterval = 1.5

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
        self.box = box
        self.imageSize = imageSize
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

    /// Follows and measures at once, with no Yes: only for the self-checkout, which the shopper
    /// can't be asked to confirm (README, "What it measures"). Products always wait for Yes.
    public func measureNow(_ id: UUID, box: CGRect, imageSize: CGSize) {
        follow(id, box: box, imageSize: imageSize)
        measure(id)
    }

    /// Keeps where the measured product is and stops tracking it, just before a hand covers it.
    /// False, changing nothing, without a valid reading to keep.
    @discardableResult
    public func anchorProduct() -> Bool {
        guard status == .measuring, sample != nil, let lastWorldPoint, let box, let imageSize else { return false }
        stopChecks(keepingReadings: true)
        anchor = Anchor(worldPoint: lastWorldPoint, box: box, imageSize: imageSize)
        status = .anchored
        return true
    }

    /// The fingertip against the anchored product, from one camera frame. Nil when not anchored or
    /// without confident depth at the fingertip.
    /// - Parameters:
    ///   - fingertip: in `snapshot.image`'s pixels from its top left.
    ///   - snapshot: the frame the fingertip was found in.
    @discardableResult
    public func handSample(at fingertip: CGPoint, in snapshot: CameraSnapshot) -> HandSample? {
        guard status == .anchored, let anchor else { return nil }
        let reading = ProductDepthEstimator.hand(at: fingertip, reaching: anchor.worldPoint, in: snapshot)
        if let reading { hand = reading }
        return reading
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

    private func stopChecks(keepingReadings: Bool = false) {
        checks?.cancel()
        checks = nil
        tracker = nil
        lastWorldPoint = nil
        if keepingReadings { return }
        sample = nil
        rejection = nil
        box = nil
        imageSize = nil
        anchor = nil
        hand = nil
    }

    /// Tracks the product in the newest frame and, once measuring, reads its depth in that same frame.
    private func check() async {
        guard let tracker, let frame = session.currentFrame.map(CameraSnapshot.init) else { return }
        let measuring = gate.isMeasuring
        let result: (box: CGRect?, reading: ProductReading?) = await withCheckedContinuation { done in
            visionQueue.async {
                let box = tracker.track(in: frame.image, imageSize: frame.imageSize)
                done.resume(returning: (box, measuring ? box.flatMap { ProductDepthEstimator.reading(of: $0, in: frame) } : nil))
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
        if let found = result.box {
            box = found
            imageSize = frame.imageSize
        }
        guard gate.isMeasuring else { return }
        let now = session.currentFrame?.timestamp ?? frame.time
        if let reading = result.reading {
            rejection = policy.rejection(of: reading.sample, now: now)
            if rejection == nil {
                sample = reading.sample
                lastWorldPoint = reading.worldPoint
            }
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
    /// reset options, so world tracking and anchors carry on.
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
