import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

final class VisualRecognitionTests: XCTestCase {
    private let target = UUID()
    private let classifierID = "test.produce"
    private func item(_ id: UUID, confirmation: Bool = true, classes: Set<String> = ["yellow_onion"]) -> CatalogItemSnapshot {
        CatalogItemSnapshot(id: id, catalogKey: "13474244", displayName: "Fresh Yellow Onion - each",
            brand: nil, normalizedTerms: [], visual: VisualCatalogMetadata(modelID: classifierID,
                classIDs: classes, allowsConfirmation: confirmation))
    }
    private func context(paused: Bool = false, meters: Double = 5) -> RecognitionContext {
        RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(timestamp: 0,
            passedLandmarkID: "home-test", metersPastLandmark: meters, isReliable: true), externalPause: paused)
    }
    private func image(_ timestamp: Double) -> RecognitionImage {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: pixelBuffer!,
            imageResolution: CGSize(width: 64, height: 48), orientation: .up)
    }
    private func session(classifier: FakeVisualClassifier, items: [CatalogItemSnapshot]? = nil) async throws -> RecognitionCoordinator {
        try await RecognitionCoordinator(targetID: target, catalog: VisualTestCatalog(items: items ?? [item(target)]),
            recognizer: UnexpectedOCR(), detector: UnexpectedTextDetector(), visualClassifier: classifier)
    }
    private func run(_ session: RecognitionCoordinator, from start: Int = 1, through end: Int = 15) async throws -> RecognitionUpdate? {
        var latest: RecognitionUpdate?
        for frame in start...end {
            let update = try await session.submit(context(), image: image(Double(frame) / 10))
            if update.result != nil { latest = update }
        }
        return latest
    }

    func testVisualPathBypassesTextAndConfirmsPersistedIdentityAfterThreeObservations() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        let first = try await run(session, through: 5)
        XCTAssertEqual(first?.result?.status, .candidate)
        let second = try await run(session, from: 6, through: 10)
        XCTAssertEqual(second?.result?.status, .candidate)
        let third = try await run(session, from: 11)
        XCTAssertEqual(third?.result?.matchedItemID, target)
        XCTAssertEqual(third?.result?.status, .confirmed)
        XCTAssertEqual(third?.confirmedObservation?.evidenceSource, .visual)
        XCTAssertEqual(third?.confirmedObservation?.side, .left)
        XCTAssertTrue(third?.result?.normalizedObservedText.isEmpty == true)
        XCTAssertNil(third?.observation)
        let calls = await classifier.calls
        XCTAssertEqual(calls, 3, "Cadence must be applied only once.")
    }

    func testGeneralCategoryDoesNotConfirmSpecificSKU() async throws {
        let session = try await session(classifier: FakeVisualClassifier(), items: [item(target, confirmation: false)])
        let update = try await run(session)
        XCTAssertEqual(update?.result?.status, .candidate)
        XCTAssertEqual(update?.result?.visualMatchReason, .categoryOnly)
        XCTAssertNil(update?.result?.matchedItemID)
        XCTAssertNil(update?.confirmedObservation)
    }

    func testCompetingModelClassOutsideCatalogPreventsConfirmation() async throws {
        let classifier = FakeVisualClassifier()
        await classifier.setPredictions([.init(identifier: "yellow_onion", score: 0.82), .init(identifier: "potato", score: 0.95)])
        let update = try await run(session(classifier: classifier))
        XCTAssertNil(update?.result?.matchedItemID)
        XCTAssertEqual(update?.result?.visualMatchReason, .insufficientEvidence)
    }

    func testTwoCatalogItemsMappedToSameClassRemainAmbiguous() async throws {
        let session = try await session(classifier: FakeVisualClassifier(), items: [item(target), item(UUID())])
        let update = try await run(session)
        XCTAssertEqual(update?.result?.visualMatchReason, .ambiguousCatalog)
        XCTAssertNil(update?.result?.matchedItemID)
    }

    func testCategoryOnlyMappingStillChecksCompetingVisualEvidence() async throws {
        let classifier = FakeVisualClassifier()
        await classifier.setPredictions([.init(identifier: "yellow_onion", score: 0.85), .init(identifier: "potato", score: 0.95)])
        let session = try await session(classifier: classifier, items: [item(target, confirmation: false)])
        let update = try await run(session)
        XCTAssertEqual(update?.result?.visualMatchReason, .insufficientEvidence)
        XCTAssertNil(update?.result?.matchedItemID)
    }

    func testGeneralVisionModelCannotConfirmSKUThroughCustomCatalogAdapter() throws {
        let targetItem = CatalogItemSnapshot(id: target, catalogKey: "13474244", displayName: "Yellow onion",
            brand: nil, normalizedTerms: [], visual: VisualCatalogMetadata(
                modelID: VisionImageClassifier.modelID, classIDs: ["onion"], allowsConfirmation: true))
        let observation = VisualObservation(timestamp: 1, modelID: VisionImageClassifier.modelID,
            modelVersion: "test", inputRegion: CGRect(x: 0, y: 0, width: 10, height: 10),
            classifications: [.init(identifier: "onion", score: 0.99)])
        let match = try VisualCatalogMatcher().match(observation, targetID: target,
            against: [targetItem], policy: VisualRecognitionPolicy())
        XCTAssertEqual(match.reason, .categoryOnly)
        XCTAssertFalse(match.accepted)
    }

    func testLowScoreEmptyAndUnmappedPredictionsReturnNoMatch() async throws {
        for predictions: [VisualClassification] in [
            [], [.init(identifier: "potato", score: 0.99)], [.init(identifier: "yellow_onion", score: 0.3)]
        ] {
            let classifier = FakeVisualClassifier()
            await classifier.setPredictions(predictions)
            let update = try await run(session(classifier: classifier))
            XCTAssertEqual(update?.result?.status, .noMatch)
            XCTAssertNil(update?.result?.matchedItemID)
        }
    }

    func testInactiveGateSkipsVisualInferenceAndStopRejectsFrames() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        let update = try await session.submit(context(meters: 0), image: image(1))
        XCTAssertEqual(update.result?.status, .disabled)
        XCTAssertEqual(update.result?.evidenceSource, .visual)
        let calls = await classifier.calls
        XCTAssertEqual(calls, 0)
        await session.stop()
        do { _ = try await session.submit(context(), image: image(2)); XCTFail("Stopped session accepted a frame") }
        catch { XCTAssertTrue(error is RecognitionSessionError) }
    }

    func testPauseDuringInferenceDiscardsOldResultAndRestartsEvidence() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        _ = try await run(session, through: 10)
        await classifier.holdNext()
        for frame in 11...14 { _ = try await session.submit(context(), image: image(Double(frame) / 10)) }
        let pending = Task { try await session.submit(context(), image: image(1.5)) }
        await classifier.waitUntilHeld()
        _ = try await session.updateContext(context(paused: true))
        _ = try await session.updateContext(context())
        await classifier.release()
        let old = try await pending.value
        XCTAssertNil(old.result)
        let fresh = try await run(session, from: 16, through: 20)
        XCTAssertEqual(fresh?.result?.status, .candidate)
    }

    func testDuplicatesAndExpiredEvidenceCannotCompleteConfirmation() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        for timestamp in [1.0, 1.0, 1.0, 0.5, 4.0] {
            var update: RecognitionUpdate?
            for _ in 0..<5 { update = try await session.submit(context(), image: image(timestamp)) }
            XCTAssertEqual(update?.result?.status, .candidate)
        }
    }

    func testModelRevisionChangeClearsEvidence() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        _ = try await run(session, through: 10)
        await classifier.setVersion("v2")
        let update = try await run(session, from: 11)
        XCTAssertEqual(update?.result?.status, .candidate)
    }

    func testFailureClearsEvidenceAndInvalidScoresAreRejected() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        _ = try await run(session, through: 10)
        await classifier.setPredictions([.init(identifier: "yellow_onion", score: .nan)])
        do { _ = try await run(session, from: 11); XCTFail("Invalid score accepted") }
        catch { XCTAssertEqual(error as? VisualRecognitionError, .invalidObservation) }
        await classifier.setPredictions([.init(identifier: "yellow_onion", score: 0.99)])
        let update = try await run(session, from: 16, through: 20)
        XCTAssertEqual(update?.result?.status, .candidate)
    }

    func testMissingClassifierAndUnsupportedMappingFailAtSessionSetup() async throws {
        do {
            _ = try await RecognitionCoordinator(targetID: target, catalog: VisualTestCatalog(items: [item(target)]))
            XCTFail("Missing classifier silently fell back to OCR")
        } catch { XCTAssertEqual(error as? VisualRecognitionError, .missingClassifier) }
        do {
            _ = try await session(classifier: FakeVisualClassifier(), items: [item(target, classes: ["unknown"])])
            XCTFail("Unsupported mapping accepted")
        } catch { XCTAssertEqual(error as? VisualRecognitionError, .unsupportedClasses) }
        do {
            _ = try CoreMLVisualClassifier(compiledModelURL: URL(fileURLWithPath: "/missing/Produce.mlmodelc"),
                modelID: "test", version: "1", cropAndScale: .centerCrop)
            XCTFail("Missing model accepted")
        } catch { XCTAssertEqual(error as? VisualRecognitionError, .missingModel) }
    }

    func testSuppliedCropReachesVisualInferenceAndInvalidCropIsRejected() async throws {
        let classifier = FakeVisualClassifier()
        let session = try await session(classifier: classifier)
        let crop = CGRect(x: 8, y: 6, width: 32, height: 24)
        var update: RecognitionUpdate?
        for frame in 1...5 { update = try await session.submit(context(), image: image(Double(frame)), crop: crop) }
        XCTAssertEqual(update?.visualObservation?.inputRegion, crop)
        do {
            _ = try await session.submit(context(), image: image(6), crop: CGRect(x: -1, y: 0, width: 10, height: 10))
            XCTFail("Invalid crop accepted")
        } catch { XCTAssertTrue(error is TextExtractionError) }
    }
}

private struct VisualTestCatalog: CatalogReading {
    let items: [CatalogItemSnapshot]
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { items }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetItemID, landmarkID: "home-test",
            activateAfterMeters: 3, deactivateAfterMeters: 20, side: .left)
    }
}

private actor FakeVisualClassifier: VisualClassifying {
    private(set) var calls = 0
    private var version = "v1"
    private var predictions = [VisualClassification(identifier: "yellow_onion", score: 0.99)]
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func modelInfo() -> VisualModelInfo {
        VisualModelInfo(id: "test.produce", version: "v1", supportedClassIDs: ["yellow_onion", "potato"])
    }
    func setPredictions(_ value: [VisualClassification]) { predictions = value }
    func setVersion(_ value: String) { version = value }
    func holdNext() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { held?.resume(); held = nil }
    func classify(in image: RecognitionImage, crop: CGRect?) async throws -> VisualObservation {
        calls += 1
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                held = continuation; started?.resume(); started = nil
            }
        }
        return VisualObservation(timestamp: image.timestamp, modelID: "test.produce", modelVersion: version,
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution), classifications: predictions)
    }
}

private struct UnexpectedOCR: TextRecognizing {
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        XCTFail("Visual mode invoked OCR"); return []
    }
}
private struct UnexpectedTextDetector: LabelRegionDetecting {
    func detectRegion(in image: RecognitionImage) async throws -> CGRect? {
        XCTFail("Visual mode invoked text detection"); return nil
    }
}
