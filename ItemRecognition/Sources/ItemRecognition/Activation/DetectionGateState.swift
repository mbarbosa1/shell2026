import Foundation

/// The activation gate's state after evaluating one `RecognitionContext`.
public enum DetectionGateState: Sendable, Equatable {
    /// The supplied landmark does not match the rule, or the rule/progress is missing.
    case waitingForLandmark
    /// The matching landmark was passed, but progress is below `activateAfterMeters`.
    case armed
    /// Reliable progress is inside the configured window. Item detection may run.
    case active
    /// An external pause or unreliable progress has suspended detection.
    case suspended
    /// Progress is past `deactivateAfterMeters`. The recognition window was passed.
    case thresholdPassed
    /// The activation rule's `isInStore` boolean is false. Detection stays off.
    case itemNotInStore
}
