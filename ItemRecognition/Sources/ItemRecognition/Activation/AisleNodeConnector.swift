import Foundation

/// One node of the lane the cart drives, in the store map's frame (metres, seen from above).
/// The app builds these from `RoutePlanner.Stop.path` and `StoreMap.Node` positions.
public struct AisleLaneNode: Sendable, Equatable {
    public let id: String
    public let x: Double
    public let y: Double

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// Turns a cart position into the landmark progress `ActivationGate` expects.
///
/// The lane's first node is the landmark. Its id must equal the target's
/// `DetectionActivationRuleSnapshot.landmarkID`, or the gate stays in `.waitingForLandmark`.
/// Progress is the distance walked along the lane from that node, so the rule's
/// `activateAfterMeters`/`deactivateAfterMeters` are metres into the aisle.
public struct AisleProgressProjector: Sendable {
    public let lane: [AisleLaneNode]
    /// How far off the lane the cart may be before progress counts as unreliable.
    public let maxLateralMeters: Double

    /// Distance along the lane at the start of each segment.
    private let startMeters: [Double]

    public init(lane: [AisleLaneNode], maxLateralMeters: Double = 2.0) {
        self.lane = lane
        self.maxLateralMeters = maxLateralMeters
        var total = 0.0
        var starts: [Double] = []
        for (a, b) in zip(lane, lane.dropFirst()) {
            starts.append(total)
            total += hypot(b.x - a.x, b.y - a.y)
        }
        startMeters = starts
    }

    public var landmarkID: String? { lane.first?.id }

    /// Before the cart reaches the first node, no landmark is reported. Past the last
    /// node, progress keeps growing so the gate can report `.thresholdPassed`.
    public func observation(x: Double, y: Double, timestamp: TimeInterval) -> LandmarkProgressObservation {
        guard lane.count >= 2, x.isFinite, y.isFinite else {
            return LandmarkProgressObservation(timestamp: timestamp, passedLandmarkID: nil,
                                               metersPastLandmark: nil, isReliable: false)
        }

        var best: (meters: Double, lateral: Double)?
        let last = lane.count - 2
        for i in 0...last {
            let a = lane[i], b = lane[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            var t = ((x - a.x) * dx + (y - a.y) * dy) / (length * length)
            // Only the ends of the lane extend beyond their nodes.
            if i > 0 { t = max(t, 0) }
            if i < last { t = min(t, 1) }
            let lateral = hypot(x - (a.x + t * dx), y - (a.y + t * dy))
            if best == nil || lateral < best!.lateral {
                best = (startMeters[i] + t * length, lateral)
            }
        }

        guard let best, best.meters >= 0 else {
            return LandmarkProgressObservation(timestamp: timestamp, passedLandmarkID: nil,
                                               metersPastLandmark: nil, isReliable: best != nil)
        }
        return LandmarkProgressObservation(timestamp: timestamp, passedLandmarkID: landmarkID,
                                           metersPastLandmark: best.meters,
                                           isReliable: best.lateral <= maxLateralMeters)
    }
}

/// Connects aisle navigation to item recognition for one target.
///
/// Call `update(x:y:timestamp:)` on every position fix. Once the cart is inside the
/// target's activation window, `submit(_:)` forwards camera frames to the coordinator;
/// outside it, frames are dropped without running Vision.
public actor AisleRecognitionLink {
    public let targetItemID: UUID
    private let coordinator: RecognitionCoordinator
    private var projector: AisleProgressProjector
    private var externalPause = false
    private var context: RecognitionContext?
    private var decision: ActivationDecision?

    public init(targetItemID: UUID, coordinator: RecognitionCoordinator, lane: AisleProgressProjector) {
        self.targetItemID = targetItemID
        self.coordinator = coordinator
        self.projector = lane
    }

    /// The latest gate decision, or nil before the first position fix.
    public var lastDecision: ActivationDecision? { decision }

    /// True while frames should be captured and sent.
    public var isDetectionActive: Bool { decision?.isDetectionActive == true }

    /// Replaces the lane, e.g. after the route is re-planned mid-trip.
    public func setLane(_ lane: AisleProgressProjector) { projector = lane }

    /// Obstacle or safety pause from navigation. Applied on the next position fix.
    public func setExternalPause(_ paused: Bool) { externalPause = paused }

    /// Projects the position onto the lane and passes the result to the activation gate.
    @discardableResult
    public func update(x: Double, y: Double, timestamp: TimeInterval) async throws -> ActivationDecision {
        let context = RecognitionContext(
            targetItemID: targetItemID,
            landmarkProgress: projector.observation(x: x, y: y, timestamp: timestamp),
            externalPause: externalPause
        )
        let decision = try await coordinator.updateContext(context)
        self.context = context
        self.decision = decision
        return decision
    }

    /// Sends a frame for recognition with the latest position context.
    /// Returns nil when detection is not active, so no frame work is done.
    public func submit(_ image: RecognitionImage, crop: CGRect? = nil) async throws -> RecognitionUpdate? {
        guard let context, decision?.isDetectionActive == true else { return nil }
        return try await coordinator.submit(context, image: image, crop: crop)
    }

    /// Ends the session, e.g. when the item is collected or the target changes.
    public func stop() async {
        decision = nil
        context = nil
        await coordinator.stop()
    }
}
