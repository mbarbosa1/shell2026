import Foundation

/// The user distance (README, "What it measures"): the shopper's fingertip against the product it's
/// reaching for, from the LiDAR depth at the fingertip.
public struct HandSample: Equatable, Sendable {
    /// Straight-line meters from the fingertip to the product's point (the middle of its box, on
    /// its surface).
    public let meters: Double
    /// Meters the product is behind the fingertip along the camera's view. Positive while the hand
    /// is lined up but short of the product; about 0 when touching it.
    public let gap: Double
    /// When the camera took the frame (`ARFrame.timestamp`, seconds).
    public let frameTime: TimeInterval

    public init(meters: Double, gap: Double, frameTime: TimeInterval) {
        self.meters = meters
        self.gap = gap
        self.frameTime = frameTime
    }
}

/// What pickup may tell the shopper once their fingertip is over the product on screen (2D):
/// whether it has actually reached the product. "Got it" needs `.touching`; covering the product
/// on screen while hovering in front of it is `.short` (user decision, September 27, 2026).
///
/// The thresholds are drafts to be set from the bench test (README step 8).
public struct HandReachPolicy: Equatable, Sendable {
    public enum Reach: Equatable, Sendable {
        /// The fingertip is at the product's depth.
        case touching
        /// Lined up, but more than `touchingGap` short of the product: reach further.
        case short
        /// Nothing to decide from this frame: no confident depth at the fingertip, an old frame, or
        /// a fingertip reading behind the product, which means it missed the finger.
        case unknown
    }

    /// How close to the product's depth the fingertip must be to count as touching it.
    public var touchingGap = 0.05
    /// Oldest frame, in seconds, a sample may come from.
    public var maximumAge: TimeInterval = 0.5

    public init() {}

    /// `now` is on the same clock as `HandSample.frameTime`.
    public func reach(_ sample: HandSample?, now: TimeInterval) -> Reach {
        guard let sample, now - sample.frameTime <= maximumAge else { return .unknown }
        if sample.gap > touchingGap { return .short }
        if sample.gap < -touchingGap { return .unknown }
        return .touching
    }
}
