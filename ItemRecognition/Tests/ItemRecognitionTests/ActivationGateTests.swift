import XCTest
@testable import ItemRecognition

/// In-memory stand-in for the database branch's SwiftData adapter.
/// Holds persisted rules keyed by target so the gate reads the landmark id
/// through `CatalogReading` exactly as it will in production.
private actor InMemoryCatalog: CatalogReading {
    private var rules: [UUID: DetectionActivationRuleSnapshot]
    private(set) var ruleReadCount = 0

    init(rules: [DetectionActivationRuleSnapshot]) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.targetItemID, $0) })
    }

    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        []
    }

    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        ruleReadCount += 1
        return rules[targetItemID]
    }

    func register(_ rule: DetectionActivationRuleSnapshot) {
        rules[rule.targetItemID] = rule
    }
}

private struct CatalogFailure: Error, Equatable {}

private struct ThrowingCatalog: CatalogReading {
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { [] }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        throw CatalogFailure()
    }
}

final class ActivationGateTests: XCTestCase {

    // MARK: - Fixtures (data only; the gate embeds none of these values)

    private let cerealID = UUID()
    private let landmark = "aisle_25_top"
    private let activateAfter = 3.0
    private let deactivateAfter = 20.0

    private func cerealRule() -> DetectionActivationRuleSnapshot {
        DetectionActivationRuleSnapshot(
            targetItemID: cerealID,
            landmarkID: landmark,
            activateAfterMeters: activateAfter,
            deactivateAfterMeters: deactivateAfter,
            side: .left
        )
    }

    private func makeGate(rules: [DetectionActivationRuleSnapshot]? = nil) -> (ActivationGate, InMemoryCatalog) {
        let catalog = InMemoryCatalog(rules: rules ?? [cerealRule()])
        return (ActivationGate(catalog: catalog), catalog)
    }

    private func context(
        target: UUID? = nil,
        landmark: String? = "aisle_25_top",
        meters: Double?,
        reliable: Bool = true,
        pause: Bool = false,
        timestamp: TimeInterval = 100
    ) -> RecognitionContext {
        RecognitionContext(
            targetItemID: target ?? cerealID,
            landmarkProgress: LandmarkProgressObservation(
                timestamp: timestamp,
                passedLandmarkID: landmark,
                metersPastLandmark: meters,
                isReliable: reliable
            ),
            externalPause: pause
        )
    }

    // MARK: - Landmark validation happens before the metre window

    func testNonFiniteProgressCannotActivateDetection() async throws {
        let (gate, _) = makeGate()
        for meters in [Double.nan, Double.infinity, -Double.infinity] {
            let decision = try await gate.evaluate(context(meters: meters))
            XCTAssertEqual(decision.inactiveReason, .invalidProgress)
            XCTAssertFalse(decision.isDetectionActive)
        }
    }

    func testInvalidRuleCannotActivateDetection() async throws {
        let rule = DetectionActivationRuleSnapshot(targetItemID: cerealID, landmarkID: landmark,
            activateAfterMeters: 10, deactivateAfterMeters: 3)
        let (gate, _) = makeGate(rules: [rule])
        let decision = try await gate.evaluate(context(meters: 5))
        XCTAssertEqual(decision.inactiveReason, .invalidActivationRule)
        XCTAssertFalse(decision.isDetectionActive)
    }

    func testDifferentLandmarkStaysWaitingAtAnyMeters() async throws {
        let (gate, _) = makeGate()

        for meters in [0.0, 2.4, 3.0, 10.0, 20.0, 50.0] {
            let decision = try await gate.evaluate(context(landmark: "aisle_24_top", meters: meters))
            XCTAssertEqual(decision.state, .waitingForLandmark, "meters=\(meters)")
            XCTAssertEqual(
                decision.inactiveReason,
                .landmarkMismatch(supplied: "aisle_24_top", expected: landmark)
            )
            XCTAssertFalse(decision.isDetectionActive)
        }
    }

    func testMatchingLandmarkBelowStartIsArmed() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(meters: 2.4))

        XCTAssertEqual(decision.state, .armed)
        XCTAssertEqual(
            decision.inactiveReason,
            .beforeActivationThreshold(meters: 2.4, activateAfterMeters: activateAfter)
        )
        XCTAssertFalse(decision.isDetectionActive)
    }

    // MARK: - The activation step

    func testActivatesExactlyAtActivateAfterMeters() async throws {
        let (gate, _) = makeGate()

        let armed = try await gate.evaluate(context(meters: 2.9))
        XCTAssertEqual(armed.state, .armed)

        let active = try await gate.evaluate(context(meters: activateAfter))
        XCTAssertEqual(active.state, .active)
        XCTAssertNil(active.inactiveReason)
        XCTAssertTrue(active.isDetectionActive)
        XCTAssertFalse(active.clearTemporalCandidates)
    }

    func testStaysActiveExactlyAtDeactivateAfterMeters() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(meters: deactivateAfter))

        XCTAssertEqual(decision.state, .active)
        XCTAssertTrue(decision.isDetectionActive)
    }

    func testTurnsOffWhenProgressIsPastDeactivateAfterMeters() async throws {
        let (gate, _) = makeGate()

        _ = try await gate.evaluate(context(meters: 10.0))
        let passed = try await gate.evaluate(context(meters: 20.01))

        XCTAssertEqual(passed.state, .thresholdPassed)
        XCTAssertEqual(
            passed.inactiveReason,
            .pastDeactivationThreshold(meters: 20.01, deactivateAfterMeters: deactivateAfter)
        )
        XCTAssertTrue(passed.clearTemporalCandidates)
        XCTAssertFalse(passed.isDetectionActive)
    }

    func testPastEndOnWrongLandmarkIsStillWaiting() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(landmark: "aisle_26_top", meters: 25.0))

        XCTAssertEqual(decision.state, .waitingForLandmark)
    }

    // MARK: - Suspension

    func testUnreliableProgressInsideWindowSuspendsAndClearsCandidates() async throws {
        let (gate, _) = makeGate()

        _ = try await gate.evaluate(context(meters: 5.0))
        let suspended = try await gate.evaluate(context(meters: 6.0, reliable: false))

        XCTAssertEqual(suspended.state, .suspended)
        XCTAssertEqual(suspended.inactiveReason, .unreliableProgress)
        XCTAssertTrue(suspended.clearTemporalCandidates)
    }

    func testExternalPauseInsideWindowSuspendsWithoutReportingPassed() async throws {
        let (gate, _) = makeGate()

        _ = try await gate.evaluate(context(meters: 5.0))
        let paused = try await gate.evaluate(context(meters: 6.0, pause: true))

        XCTAssertEqual(paused.state, .suspended)
        XCTAssertEqual(paused.inactiveReason, .externalPause)
        XCTAssertNotEqual(paused.state, .thresholdPassed)
        XCTAssertTrue(paused.clearTemporalCandidates)
    }

    func testExternalPauseWinsOverEverythingElse() async throws {
        let (gate, _) = makeGate(rules: [])

        let decision = try await gate.evaluate(context(landmark: nil, meters: nil, pause: true))

        XCTAssertEqual(decision.state, .suspended)
        XCTAssertEqual(decision.inactiveReason, .externalPause)
    }

    func testResumeAfterSuspensionReactivatesWithoutCarryingCandidates() async throws {
        let (gate, _) = makeGate()

        _ = try await gate.evaluate(context(meters: 5.0))
        let suspended = try await gate.evaluate(context(meters: 6.0, pause: true))
        XCTAssertTrue(suspended.clearTemporalCandidates)

        let resumed = try await gate.evaluate(context(meters: 7.0))
        XCTAssertEqual(resumed.state, .active)
        XCTAssertFalse(resumed.clearTemporalCandidates)
    }

    // MARK: - Missing inputs

    func testItemNotInStoreStaysInactiveInsideWindow() async throws {
        let outOfStore = DetectionActivationRuleSnapshot(
            targetItemID: cerealID,
            landmarkID: landmark,
            activateAfterMeters: activateAfter,
            deactivateAfterMeters: deactivateAfter,
            side: .left,
            isInStore: false
        )
        let (gate, _) = makeGate(rules: [outOfStore])

        let decision = try await gate.evaluate(context(meters: 10.0))

        XCTAssertEqual(decision.state, .itemNotInStore)
        XCTAssertEqual(decision.inactiveReason, .itemNotInStore)
        XCTAssertFalse(decision.isDetectionActive)
        XCTAssertTrue(decision.clearTemporalCandidates)
    }

    func testMissingRuleStaysInactiveWithTypedReason() async throws {
        let (gate, _) = makeGate(rules: [])

        let decision = try await gate.evaluate(context(meters: 10.0))

        XCTAssertEqual(decision.state, .waitingForLandmark)
        XCTAssertEqual(decision.inactiveReason, .missingActivationRule)
    }

    func testMissingLandmarkIDStaysInactiveWithTypedReason() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(landmark: nil, meters: 10.0))

        XCTAssertEqual(decision.state, .waitingForLandmark)
        XCTAssertEqual(decision.inactiveReason, .missingLandmark)
    }

    func testMissingMetersStaysInactiveWithTypedReason() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(meters: nil))

        XCTAssertEqual(decision.state, .waitingForLandmark)
        XCTAssertEqual(decision.inactiveReason, .missingProgress)
    }

    func testRuleRegisteredAfterFirstEvaluationIsPickedUp() async throws {
        let (gate, catalog) = makeGate(rules: [])

        let before = try await gate.evaluate(context(meters: 10.0))
        XCTAssertEqual(before.inactiveReason, .missingActivationRule)

        await catalog.register(cerealRule())
        let after = try await gate.evaluate(context(meters: 10.0))
        XCTAssertEqual(after.state, .active)
    }

    func testCatalogErrorPropagatesAsIntegrationError() async {
        let gate = ActivationGate(catalog: ThrowingCatalog())

        do {
            _ = try await gate.evaluate(context(meters: 10.0))
            XCTFail("expected the catalog error to propagate")
        } catch let error as CatalogFailure {
            XCTAssertEqual(error, CatalogFailure())
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Target lifecycle

    func testNewTargetResetsGateBeforeComparingNewRule() async throws {
        let milkID = UUID()
        let milkRule = DetectionActivationRuleSnapshot(
            targetItemID: milkID,
            landmarkID: "aisle_30_top",
            activateAfterMeters: 2.0,
            deactivateAfterMeters: 15.0,
            side: .right
        )
        let (gate, catalog) = makeGate(rules: [cerealRule(), milkRule])

        let cerealActive = try await gate.evaluate(context(meters: 10.0))
        XCTAssertEqual(cerealActive.state, .active)

        // Same landmark and metres that were active for cereal; new target means new rule.
        let switched = try await gate.evaluate(context(target: milkID, meters: 10.0))
        XCTAssertEqual(switched.state, .waitingForLandmark)
        XCTAssertEqual(
            switched.inactiveReason,
            .landmarkMismatch(supplied: landmark, expected: "aisle_30_top")
        )
        XCTAssertTrue(switched.clearTemporalCandidates)

        let loaded = await gate.loadedRule
        XCTAssertEqual(loaded, milkRule)
        let reads = await catalog.ruleReadCount
        XCTAssertEqual(reads, 2, "one rule read per target, none per observation")
    }

    func testFreshGateActivatesFromSingleMatchingObservation() async throws {
        let (gate, _) = makeGate()

        let decision = try await gate.evaluate(context(meters: 12.0))

        XCTAssertEqual(decision.state, .active)
        XCTAssertNil(decision.inactiveReason)
        // The first target is a new target: the matcher starts with a clean
        // candidate window even though the gate went straight to .active.
        XCTAssertTrue(decision.clearTemporalCandidates)

        let next = try await gate.evaluate(context(meters: 13.0))
        XCTAssertEqual(next.state, .active)
        XCTAssertFalse(next.clearTemporalCandidates)
    }

    func testLeavingActiveWindowBackwardsClearsCandidates() async throws {
        let (gate, _) = makeGate()

        _ = try await gate.evaluate(context(meters: 5.0))
        let backedUp = try await gate.evaluate(context(meters: 1.0))

        XCTAssertEqual(backedUp.state, .armed)
        XCTAssertTrue(backedUp.clearTemporalCandidates, "leaving .active must drop stale candidates")

        let reentered = try await gate.evaluate(context(meters: 4.0))
        XCTAssertEqual(reentered.state, .active)
        XCTAssertFalse(reentered.clearTemporalCandidates)
    }

    func testCurrentStateDefaultsToWaitingBeforeFirstEvaluation() async {
        let (gate, _) = makeGate()

        let state = await gate.currentState
        let last = await gate.lastDecision

        XCTAssertEqual(state, .waitingForLandmark)
        XCTAssertNil(last)
    }
}
