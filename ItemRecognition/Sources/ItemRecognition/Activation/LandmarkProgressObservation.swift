import Foundation

// which landmark node was passed most recently and how far the cart has travelled past it.
public struct LandmarkProgressObservation: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let passedLandmarkID: String?
    public let metersPastLandmark: Double?
    public let isReliable: Bool

    public init(
        timestamp: TimeInterval,
        passedLandmarkID: String?,
        metersPastLandmark: Double?,
        isReliable: Bool
    ) {
        self.timestamp = timestamp
        self.passedLandmarkID = passedLandmarkID
        self.metersPastLandmark = metersPastLandmark
        self.isReliable = isReliable
    }
}
