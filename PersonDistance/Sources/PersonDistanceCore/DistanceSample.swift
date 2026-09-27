import Foundation

/// One LiDAR scene-depth reading of how far a product is from the phone's camera.
public struct DistanceSample: Equatable, Sendable {
    /// Straight-line meters from the camera to the product's surface.
    public let meters: Double
    /// Share (0–1) of the depth pixels over the product that were confident enough to use.
    public let coverage: Double
    /// Meters between the 25th and 75th percentile of those depths: how evenly the surface read.
    public let spread: Double
    /// When the camera took the frame the reading came from (`ARFrame.timestamp`, seconds).
    public let frameTime: TimeInterval

    public init(meters: Double, coverage: Double, spread: Double, frameTime: TimeInterval) {
        self.meters = meters
        self.coverage = coverage
        self.spread = spread
        self.frameTime = frameTime
    }
}
