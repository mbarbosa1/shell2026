import Foundation

/// Whether a reading is good enough to show or act on. A reading that fails gives no distance at
/// all rather than a guess (README step 6: abstain when the association is doubtful).
///
/// The thresholds are drafts to be set from the first bench test (README step 11), not measured.
public struct SpatialValidityPolicy: Equatable, Sendable {
    public enum Rejection: Equatable, Sendable {
        /// Too few confident depth pixels over the product.
        case lowCoverage
        /// The depths over the product disagree: likely an edge, a gap, or something in front.
        case uneven
        /// The frame is too old for the phone's position now.
        case stale
    }

    /// Share of the product's depth pixels that must be confident.
    public var minimumCoverage = 0.3
    /// Largest spread (meters, 25th–75th percentile) for one flat-ish product face.
    public var maximumSpread = 0.08
    /// Oldest frame, in seconds, a reading may come from.
    public var maximumAge: TimeInterval = 0.5

    public init() {}

    /// Nil when `sample` is valid at `now` (the same clock as `DistanceSample.frameTime`).
    public func rejection(of sample: DistanceSample, now: TimeInterval) -> Rejection? {
        if sample.coverage < minimumCoverage { return .lowCoverage }
        if sample.spread > maximumSpread { return .uneven }
        if now - sample.frameTime > maximumAge { return .stale }
        return nil
    }
}
