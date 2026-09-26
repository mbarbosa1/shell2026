import Foundation

/// Decides whether item detection is allowed to run.
///
/// This actor is the only place in the package that produces
/// `DetectionGateState.active`. It compares the landmark progress supplied by
/// upstream localization with the activation rule persisted by the database
/// branch. It never derives position, never reads camera frames, and never
/// stores OCR candidates.
///
/// Evaluation order for every `RecognitionContext`, fixed so that a large
/// metre value on the wrong landmark can never activate detection and a value
/// past the end of the window can never remain active:
///
/// 1. A new target id resets the gate and reloads the rule.
/// 2. `externalPause` suspends.
/// 3. A missing rule keeps detection off with a typed reason.
/// 4. `isItemInStore` must be true. A false boolean keeps detection off.
/// 5. Missing landmark id or metres keeps detection off with a typed reason.
/// 6. The supplied landmark id must equal the persisted `landmarkID`.
/// 7. Progress must be reliable.
/// 8. Progress greater than `deactivateAfterMeters` means the window was passed.
/// 9. Progress less than `activateAfterMeters` means armed.
/// 10. Otherwise active. Both bounds are inside the window.
public actor ActivationGate {
    private let catalog: any CatalogReading

    private var currentTargetID: UUID?
    private var currentRule: DetectionActivationRuleSnapshot?
    private var previousDecision: ActivationDecision?

    public init(catalog: any CatalogReading) {
        self.catalog = catalog
    }

    /// The most recent decision, or `nil` before the first evaluation.
    public var lastDecision: ActivationDecision? { previousDecision }

    /// The most recent state, or `.waitingForLandmark` before the first evaluation.
    public var currentState: DetectionGateState {
        previousDecision?.state ?? .waitingForLandmark
    }

    /// The rule currently loaded for the active target, if any.
    public var loadedRule: DetectionActivationRuleSnapshot? { currentRule }

    /// Evaluates one context and returns the resulting decision.
    ///
    /// Throws only when `CatalogReading.activationRule(for:)` throws. That is
    /// the database branch's typed integration error and is passed through
    /// unchanged rather than being turned into a guess.
    public func evaluate(_ context: RecognitionContext) async throws -> ActivationDecision {
        let targetChanged = try await resetIfTargetChanged(to: context.targetItemID)
        let previousState = targetChanged ? nil : previousDecision?.state

        let (state, reason) = classify(context)
        let clear = shouldClearTemporalCandidates(
            targetChanged: targetChanged,
            previousState: previousState,
            newState: state
        )

        let decision = ActivationDecision(
            state: state,
            inactiveReason: reason,
            clearTemporalCandidates: clear
        )
        previousDecision = decision
        return decision
    }

    // MARK: - Target lifecycle

    /// Returns `true` when the target differed from the stored one. The first
    /// target set on a fresh gate counts as a change, so the first decision
    /// always asks the matcher to start with a clean candidate window.

    private func resetIfTargetChanged(to targetItemID: UUID) async throws -> Bool {
        let changed = currentTargetID != targetItemID
        if changed {
            currentTargetID = targetItemID
            currentRule = nil
            previousDecision = nil
        }
        if currentRule == nil {
            currentRule = try await catalog.activationRule(for: targetItemID)
        }
        return changed
    }

    // MARK: - Classification
    private func classify(
        _ context: RecognitionContext
    ) -> (DetectionGateState, ActivationInactiveReason?) {
        if context.externalPause {
            return (.suspended, .externalPause)
        }

        guard let rule = currentRule else {
            return (.waitingForLandmark, .missingActivationRule)
        }
        guard rule.targetItemID == context.targetItemID, !rule.landmarkID.isEmpty,
              rule.activateAfterMeters.isFinite, rule.deactivateAfterMeters.isFinite,
              rule.activateAfterMeters >= 0, rule.deactivateAfterMeters >= rule.activateAfterMeters else {
            return (.suspended, .invalidActivationRule)
        }

        if !isItemInStore(rule) {
            return (.itemNotInStore, .itemNotInStore)
        }

        let progress = context.landmarkProgress

        guard let suppliedLandmark = progress.passedLandmarkID else {
            return (.waitingForLandmark, .missingLandmark)
        }

        guard let meters = progress.metersPastLandmark else {
            return (.waitingForLandmark, .missingProgress)
        }
        guard meters.isFinite else { return (.suspended, .invalidProgress) }

        guard suppliedLandmark == rule.landmarkID else {
            return (
                .waitingForLandmark,
                .landmarkMismatch(supplied: suppliedLandmark, expected: rule.landmarkID)
            )
        }

        guard progress.isReliable else {
            return (.suspended, .unreliableProgress)
        }

        if meters > rule.deactivateAfterMeters {
            return (
                .thresholdPassed,
                .pastDeactivationThreshold(
                    meters: meters,
                    deactivateAfterMeters: rule.deactivateAfterMeters
                )
            )
        }

        if meters < rule.activateAfterMeters {
            return (
                .armed,
                .beforeActivationThreshold(
                    meters: meters,
                    activateAfterMeters: rule.activateAfterMeters
                )
            )
        }

        return (.active, nil)
    }

    /// Boolean store-membership check.
    ///
    /// Add store conditions in this function. Return `true` only when the item
    /// is carried at this store. `classify` calls this after the activation
    /// rule is loaded and before landmark metres can turn detection on, so a
    /// `false` result keeps the gate off inside the metre window.
    private func isItemInStore(_ rule: DetectionActivationRuleSnapshot) -> Bool {
        if rule.isInStore {
            return true
        }
        return false
    }

    // MARK: - Candidate clearing
    private func shouldClearTemporalCandidates(
        targetChanged: Bool,
        previousState: DetectionGateState?,
        newState: DetectionGateState
    ) -> Bool {
        if targetChanged { return true }
        switch newState {
        case .suspended, .thresholdPassed, .itemNotInStore:
            return true
        case .active:
            return false
        case .waitingForLandmark, .armed:
            return previousState == .active
        }
    }
}
