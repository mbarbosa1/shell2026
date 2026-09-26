import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

final class CatalogMatchingTests: XCTestCase {
    private let targetID = UUID()
    private let neighborID = UUID()
    private func candidate(_ id: UUID, _ title: String) -> CatalogItemSnapshot {
        CatalogItemSnapshot(id: id, catalogKey: id.uuidString, displayName: title, brand: "Acme",
                            normalizedTerms: TextNormalizer().tokens(from: title))
    }
    private var candidates: [CatalogItemSnapshot] {
        [candidate(targetID, "Acme Oat Cereal Honey 12oz"), candidate(neighborID, "Acme Oat Cereal Chocolate 12oz")]
    }
    private func observation(_ text: String, confidence: Float = 1) -> ProductTextObservation {
        ProductTextObservation(timestamp: 1, targetItemID: targetID, boundingBox: .zero,
            candidates: [RecognizedTextCandidate(rawText: text, normalizedText: TextNormalizer().normalize(text),
                confidence: confidence, boundingBox: .zero)], side: nil)
    }
    func testExactVariantWinsAndConflictingVariantIsRejected() {
        let matches = CatalogMatcher().match(observation("ACME OAT CEREAL HONEY 12 OZ"), against: candidates)
        XCTAssertEqual(matches.first?.itemID, targetID)
        XCTAssertEqual(matches.first?.score, 1)
        XCTAssertEqual(matches.last?.score, 0)
        XCTAssertTrue(matches.last?.conflicts.contains("honey") == true)
    }
    func testNeighborVariantCannotConfirmTarget() {
        let matches = CatalogMatcher().match(observation("Acme Oat Cereal Chocolate 12oz"), against: candidates)
        XCTAssertEqual(matches.first?.itemID, neighborID)
        XCTAssertEqual(matches.first { $0.itemID == targetID }?.score, 0)
    }
    func testGenericTextAndMixedVariantsAreNotAccepted() {
        for text in ["NEW ORIGINAL FAMILY", "Acme Oat Cereal Honey Chocolate 12oz"] {
            XCTAssertTrue(CatalogMatcher().match(observation(text), against: candidates).allSatisfy { $0.score == 0 })
        }
    }
    func testLowOCRConfidenceReducesEvidenceScore() {
        let matches = CatalogMatcher().match(observation("Acme Oat Cereal Honey 12oz", confidence: 0.2), against: candidates)
        XCTAssertEqual(matches.first?.score ?? -1, 0.2, accuracy: 0.001)
    }
    func testTemporalConfirmationExpiresAndRejectsDuplicateFrames() {
        var confirmation = TemporalConfirmation(requiredObservations: 3, maximumGap: 2)
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 1, accepted: true))
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 1, accepted: true))
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 2, accepted: true))
        XCTAssertTrue(confirmation.observe(targetID: targetID, timestamp: 3, accepted: true))
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 10, accepted: true))
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 11, accepted: false))
        XCTAssertFalse(confirmation.observe(targetID: targetID, timestamp: 12, accepted: true))
        XCTAssertFalse(confirmation.observe(targetID: neighborID, timestamp: 13, accepted: true))
    }

    func testCoordinatorConfirmsOnlyAfterThreeEligibleObservations() async throws {
        let session = try await session()
        var result: ItemRecognitionResult?
        for index in 1...15 {
            result = try await session.submit(context(), image: image(Double(index) / 10)).result ?? result
            if index == 5 || index == 10 { XCTAssertEqual(result?.status, .candidate) }
        }
        XCTAssertEqual(result?.status, .confirmed)
        XCTAssertEqual(result?.matchedItemID, targetID)
    }

    func testCoordinatorPauseClearsConfirmationAndFreshCadenceIsRequired() async throws {
        let session = try await session()
        for index in 1...10 { _ = try await session.submit(context(), image: image(Double(index) / 10)) }
        let paused = try await session.updateContext(context(pause: true))
        XCTAssertEqual(paused.state, .suspended)
        for index in 11...14 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            XCTAssertNil(update.result)
        }
        let fresh = try await session.submit(context(), image: image(1.5))
        XCTAssertEqual(fresh.result?.status, .candidate)
    }

    func testCoordinatorInactiveContextDoesNotRunOCRAndStopEndsSession() async throws {
        let recognizer = MatchingRecognizer()
        let session = try await session(recognizer: recognizer)
        let update = try await session.submit(context(meters: 1), image: image(1))
        XCTAssertEqual(update.result?.status, .disabled)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0)
        await session.stop()
        do { _ = try await session.submit(context(), image: image(2)); XCTFail("Stopped session must reject frames") }
        catch { XCTAssertTrue(error is RecognitionSessionError) }
    }

    func testOCRUpdatesReportOCRModeAndCarryDetectorGuidance() async throws {
        let session = try await session(detector: MatchingRegion(guidance: .moveRight))
        var processed: RecognitionUpdate?
        for index in 1...5 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            XCTAssertEqual(update.modeNotice, .ocrOnly, "every update names the recognizer, even skipped frames")
            if update.result != nil { processed = update }
        }
        XCTAssertEqual(processed?.guidance, .moveRight, "an off-centre package still reads, with a hint")
        XCTAssertEqual(processed?.result?.status, .candidate)
    }

    func testIllegibleTextSkipsOCRButStillTellsTheUserToMoveCloser() async throws {
        let recognizer = MatchingRecognizer()
        let session = try await session(recognizer: recognizer, detector: MatchingRegion(crop: nil, guidance: .moveCloser))
        var processed: RecognitionUpdate?
        for index in 1...5 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.result != nil { processed = update }
        }
        XCTAssertEqual(processed?.guidance, .moveCloser)
        XCTAssertEqual(processed?.guidance?.message, "Move closer to the item")
        XCTAssertEqual(processed?.result?.status, .noMatch)
        XCTAssertNil(processed?.observation)
        XCTAssertEqual(processed?.modeNotice, .ocrOnly)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0, "no crop means OCR never ran on interpolated pixels")
    }

    func testDisabledGateStillNamesTheSessionMode() async throws {
        let update = try await session().submit(context(meters: 1), image: image(1))
        XCTAssertEqual(update.result?.status, .disabled)
        XCTAssertEqual(update.modeNotice, .ocrOnly)
        XCTAssertNil(update.guidance)
    }

    private func session(recognizer: MatchingRecognizer = MatchingRecognizer(),
                         detector: MatchingRegion = MatchingRegion()) async throws -> RecognitionCoordinator {
        try await RecognitionCoordinator(targetID: targetID, catalog: MatchingCatalog(targetID: targetID, candidates: candidates),
            recognizer: recognizer, detector: detector)
    }
    private func context(meters: Double = 5, pause: Bool = false) -> RecognitionContext {
        RecognitionContext(targetItemID: targetID, landmarkProgress: LandmarkProgressObservation(timestamp: 0,
            passedLandmarkID: "aisle", metersPastLandmark: meters, isReliable: true), externalPause: pause)
    }
    private func image(_ timestamp: Double) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!, imageResolution: CGSize(width: 64, height: 48), orientation: .up)
    }
}

private struct MatchingCatalog: CatalogReading {
    let targetID: UUID
    let candidates: [CatalogItemSnapshot]
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { candidates }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetID, landmarkID: "aisle", activateAfterMeters: 3, deactivateAfterMeters: 20)
    }
}
private struct MatchingRegion: LabelRegionDetecting {
    var crop: CGRect? = CGRect(x: 0, y: 0, width: 64, height: 48)
    var guidance: RecognitionGuidance?
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        LabelRegionDetection(crop: crop, guidance: guidance)
    }
}
private actor MatchingRecognizer: TextRecognizing {
    private(set) var calls = 0
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        calls += 1
        return [RecognizedTextLine(text: "Acme Oat Cereal Honey 12oz", confidence: 1, boundingBox: .zero)]
    }
}
