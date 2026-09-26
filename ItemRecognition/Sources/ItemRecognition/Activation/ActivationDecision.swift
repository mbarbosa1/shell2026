import Foundation

/// Why the gate is not `.active`. Present whenever `ActivationDecision.state`
/// is anything other than `.active`.
public enum ActivationInactiveReason: Sendable, Equatable {
    /// `RecognitionContext.externalPause` was true.
    case externalPause
    /// `CatalogReading.activationRule(for:)` returned no rule for the target.
    case missingActivationRule
    /// The observation carried no `passedLandmarkID`.
    case missingLandmark
    /// The observation carried no `metersPastLandmark`.
    case missingProgress
    /// The supplied landmark id differs from the persisted `landmarkID`.
    case landmarkMismatch(supplied: String, expected: String)
    /// The observation was flagged unreliable by upstream localization.
    case unreliableProgress
    /// Progress is past `deactivateAfterMeters`.
    case pastDeactivationThreshold(meters: Double, deactivateAfterMeters: Double)
    /// Progress has not yet reached `activateAfterMeters`.
    case beforeActivationThreshold(meters: Double, activateAfterMeters: Double)
    /// `DetectionActivationRuleSnapshot.isInStore` is false.
    case itemNotInStore
}

/// The typed result of one gate evaluation.
public struct ActivationDecision: Sendable, Equatable {
    public let state: DetectionGateState
    public let inactiveReason: ActivationInactiveReason?
    public let clearTemporalCandidates: Bool

    public init(
        state: DetectionGateState,
        inactiveReason: ActivationInactiveReason?,
        clearTemporalCandidates: Bool
    ) {
        self.state = state
        self.inactiveReason = inactiveReason
        self.clearTemporalCandidates = clearTemporalCandidates
    }

    /// True only when item detection is allowed to run.
    public var isDetectionActive: Bool { state == .active }
}
