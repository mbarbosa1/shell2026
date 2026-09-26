import Foundation

// the current target, the latest landmark progress, and
/// whether an external system (safety, navigation) has paused recognition.
public struct RecognitionContext: Sendable, Equatable {
    public let targetItemID: UUID
    public let landmarkProgress: LandmarkProgressObservation
    public let externalPause: Bool

    public init(
        targetItemID: UUID,
        landmarkProgress: LandmarkProgressObservation,
        externalPause: Bool
    ) {
        self.targetItemID = targetItemID
        self.landmarkProgress = landmarkProgress
        self.externalPause = externalPause
    }
}
