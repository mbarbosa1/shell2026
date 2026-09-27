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
    private func packaged(_ title: String, type: String, id: UUID? = nil) -> CatalogItemSnapshot {
        let itemID = id ?? targetID
        return CatalogItemSnapshot(id: itemID, catalogKey: itemID.uuidString, displayName: title, brand: nil,
                                   normalizedTerms: TextNormalizer().tokens(from: title), itemType: type)
    }
    private func lines(_ rows: [(String, CGRect)]) -> ProductTextObservation {
        ProductTextObservation(timestamp: 1, targetItemID: targetID, boundingBox: .zero,
            candidates: rows.map { text, box in
                RecognizedTextCandidate(rawText: text, normalizedText: TextNormalizer().normalize(text),
                    confidence: 1, boundingBox: box)
            }, side: nil)
    }
    func testFruitAndVegetablesAreAppearanceItems() {
        let fruit = CatalogItemSnapshot(id: targetID, catalogKey: "a", displayName: "Apple", brand: nil, normalizedTerms: [], itemType: "Fruit")
        let vegetables = CatalogItemSnapshot(id: targetID, catalogKey: "b", displayName: "Onion", brand: nil, normalizedTerms: [], itemType: "Vegetables")
        let crackers = CatalogItemSnapshot(id: targetID, catalogKey: "c", displayName: "Crackers", brand: nil, normalizedTerms: [], itemType: "Crackers")
        XCTAssertTrue(fruit.recognizesByAppearance)
        XCTAssertTrue(vegetables.recognizesByAppearance)
        XCTAssertFalse(crackers.recognizesByAppearance)
    }

    func testShelfIndexLooksUpAnchorAndTitleInOneRead() {
        let cereal = packaged("Cookie Crisp Cereal 18.3oz", type: "Cold Cereals")
        let crackers = packaged("Cheez-It Original Crackers 12.4oz", type: "Crackers", id: neighborID)
        let index = ShelfWordIndex(candidates: [cereal, crackers])
        XCTAssertEqual(index.itemIDs(for: "cereal"), [targetID])
        XCTAssertEqual(index.itemIDs(for: "cracker"), [neighborID])
        XCTAssertTrue(index.itemIDs(matching: "cheez").contains(neighborID))
        XCTAssertTrue(index.anchors(for: targetID).contains("cereal"))
    }

    func testColdCerealsAnchorsOnCereal() {
        let words = ItemTypeAnchor.words(from: "Cold Cereals")
        XCTAssertTrue(words.contains("cereal"))
        XCTAssertTrue(words.contains("cereals"))
        XCTAssertFalse(words.contains("cold"))
        XCTAssertTrue(ItemTypeAnchor.words(from: "Fruit").isEmpty)
        XCTAssertTrue(ItemTypeAnchor.words(from: "Vegetables").isEmpty)
        XCTAssertTrue(ItemTypeAnchor.words(from: "Crackers").contains("cracker"))
        let chips = ItemTypeAnchor.words(from: "Chips, Puffs and Pretzels")
        XCTAssertTrue(chips.contains("chips"))
        XCTAssertTrue(chips.contains("puffs"))
        XCTAssertTrue(chips.contains("pretzels"))
    }

    func testPackagedMatchRequiresAnchorWord() {
        let target = packaged("Cheez-It Original Crackers 12.4oz", type: "Crackers")
        let matches = CatalogMatcher().match(observation("Cheez-It Original 12.4oz"), against: [target],
                                            targetID: targetID)
        XCTAssertEqual(matches.first?.score, 0)
    }

    func testNearbyCompanionCountsAndDistantSizeDoesNot() {
        let target = packaged("Cheez-It Original Crackers 12.4oz", type: "Crackers")
        let index = ShelfWordIndex(candidates: [target])
        let observation = lines([
            ("CRACKERS", CGRect(x: 0.20, y: 0.50, width: 0.30, height: 0.08)),
            ("Cheez-It", CGRect(x: 0.20, y: 0.60, width: 0.25, height: 0.06)),
            ("12.4oz", CGRect(x: 0.70, y: 0.05, width: 0.20, height: 0.05)),
        ])
        let matches = CatalogMatcher().match(observation, against: [target], targetID: targetID, index: index)
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0)
        XCTAssertTrue(matches.first?.matchedTerms.contains("cheez-it") == true)
        XCTAssertTrue(matches.first?.matchedTerms.contains("crackers") == true)
        XCTAssertFalse(matches.first?.matchedTerms.contains("12.4oz") == true)
    }

    func testTwoDistantCrackerClustersDoNotConfirm() {
        let cheez = packaged("Cheez-It Original Crackers 12.4oz", type: "Crackers")
        let ritz = packaged("Ritz Original Crackers 13.7oz", type: "Crackers", id: neighborID)
        let index = ShelfWordIndex(candidates: [cheez, ritz])
        let observation = lines([
            ("CRACKERS", CGRect(x: 0.15, y: 0.72, width: 0.30, height: 0.08)),
            ("Cheez-It Original 12.4oz", CGRect(x: 0.15, y: 0.82, width: 0.40, height: 0.06)),
            ("CRACKERS", CGRect(x: 0.15, y: 0.10, width: 0.30, height: 0.08)),
            ("Ritz Original 13.7oz", CGRect(x: 0.15, y: 0.20, width: 0.40, height: 0.06)),
        ])
        let matches = CatalogMatcher().match(observation, against: [cheez, ritz], targetID: targetID, index: index)
        XCTAssertTrue(matches.allSatisfy { $0.score == 0 })
    }

    func testMinuteDeadlineTellsTheUserToMoveOn() async throws {
        let session = try await session()
        let started = try await session.submit(context(), image: image(0))
        XCTAssertNil(started.advanceNotice)
        let expired = try await session.submit(context(), image: image(60))
        XCTAssertEqual(expired.advanceNotice, ScanDeadline.expiredMessage)
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

    func testCoordinatorAsksAfterOneClearFrame() async throws {
        let session = try await session()
        var update: RecognitionUpdate?
        for index in 1...5 { update = try await session.submit(context(), image: image(Double(index) / 10)) }
        XCTAssertEqual(update?.result?.status, .confirmed, "the first processed frame that clearly matches asks the shopper")
        XCTAssertEqual(update?.result?.matchedItemID, targetID)
        XCTAssertEqual(update?.awaitingVerdict, true)
    }

    func testCoordinatorPauseClearsConfirmationAndFreshCadenceIsRequired() async throws {
        let session = try await session()
        for index in 1...10 { _ = try await session.submit(context(), image: image(Double(index) / 10)) }
        let paused = try await session.updateContext(context(pause: true))
        XCTAssertEqual(paused.state, .suspended)
        for index in 11...14 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            XCTAssertNil(update.result, "the pause dropped the pending question")
        }
        let fresh = try await session.submit(context(), image: image(1.5))
        XCTAssertEqual(fresh.result?.status, .confirmed)
        XCTAssertEqual(fresh.result?.timestamp, 1.5, "asked again from a fresh frame, not the old one")
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
        // Three observations keep the frame a candidate, so its hint is not hidden by a question.
        let session = try await session(detector: MatchingRegion(guidance: .moveRight),
                                        policy: RecognitionPolicy(requiredObservations: 3))
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

    func testPackagedItemStaysOnOCR() async throws {
        let vision = FallbackVision()
        let session = try await session(detector: MatchingRegion(crop: nil, guidance: .moveCloser), ocrFallback: vision)
        var processed: [RecognitionUpdate] = []
        for index in 1...15 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.result != nil { processed.append(update) }
        }
        XCTAssertEqual(processed[0].modeNotice, .ocrOnly)
        XCTAssertEqual(processed[0].guidance, .moveCloser)
        XCTAssertEqual(processed.last?.modeNotice, .ocrOnly)
        let calls = await vision.calls
        XCTAssertEqual(calls, 0)
    }

    func testFruitStartsOnAppleVisionAndAsksForTheSelectedProduct() async throws {
        let vision = FallbackVision()
        let fruit = CatalogItemSnapshot(id: targetID, catalogKey: "apple", displayName: "Gala Apple",
            brand: nil, normalizedTerms: [], visual: VisualCatalogMetadata(modelID: "fallback.vision",
                classIDs: ["onion"], allowsConfirmation: true), itemType: "Fruit")
        let session = try await RecognitionCoordinator(targetID: targetID,
            catalog: MatchingCatalog(targetID: targetID, candidates: [fruit]),
            recognizer: MatchingRecognizer(), visualClassifier: vision, assessor: FixedAssessment())
        var settled: RecognitionUpdate?
        for index in 1...15 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.result != nil, !update.awaitingVerdict { XCTAssertEqual(update.guidance, .moveBack) }
            if update.awaitingVerdict { settled = update }
        }
        let verdict = try XCTUnwrap(settled)
        XCTAssertEqual(verdict.modeNotice, .appleVision)
        XCTAssertEqual(verdict.insight, "Gala Apple")
        XCTAssertNil(verdict.confirmedObservation)
        let accepted = await session.acceptInsight()
        XCTAssertEqual(accepted?.itemID, targetID)
    }

    func testConfirmedOCRWaitsForTheUser() async throws {
        let recognizer = MatchingRecognizer()
        let session = try await session(recognizer: recognizer)
        var settled: RecognitionUpdate?
        for index in 1...15 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.awaitingVerdict { settled = update }
        }
        let verdict = try XCTUnwrap(settled)
        XCTAssertEqual(verdict.result?.status, .confirmed)
        XCTAssertEqual(verdict.insight, "Acme Oat Cereal Honey 12oz")
        let calls = await recognizer.calls
        _ = try await session.submit(context(), image: image(1.6))
        let held = await recognizer.calls
        XCTAssertEqual(held, calls, "confirmation stops OCR until the user answers")
        await session.rejectInsight()
        for index in 16...20 {
            _ = try await session.submit(context(), image: image(Double(index) / 10))
        }
        let resumed = await recognizer.calls
        XCTAssertGreaterThan(resumed, calls)
    }

    private func session(recognizer: MatchingRecognizer = MatchingRecognizer(),
                         detector: MatchingRegion = MatchingRegion(),
                         ocrFallback: (any VisualClassifying)? = nil,
                         policy: RecognitionPolicy = RecognitionPolicy()) async throws -> RecognitionCoordinator {
        try await RecognitionCoordinator(targetID: targetID, catalog: MatchingCatalog(targetID: targetID, candidates: candidates),
            recognizer: recognizer, detector: detector, policy: policy, ocrFallback: ocrFallback, assessor: nil)
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
private struct FixedAssessment: FrameAssessing {
    func assess(_ image: RecognitionImage) async throws -> FrameAssessment {
        FrameAssessment(objectRegion: CGRect(x: 8, y: 8, width: 32, height: 24), quality: .usable, guidance: .moveBack)
    }
}
private struct MatchingRegion: LabelRegionDetecting {
    var crop: CGRect? = CGRect(x: 0, y: 0, width: 64, height: 48)
    var guidance: RecognitionGuidance?
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        LabelRegionDetection(crop: crop, guidance: guidance)
    }
}
private actor FallbackVision: VisualClassifying {
    private(set) var calls = 0
    func modelInfo() -> VisualModelInfo {
        VisualModelInfo(id: "fallback.vision", version: "1", supportedClassIDs: ["onion", "unknown"])
    }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        calls += 1
        return VisualObservation(timestamp: image.timestamp, modelID: "fallback.vision", modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: "onion", score: 0.95), .init(identifier: "unknown", score: 0.1)])
    }
}

private actor MatchingRecognizer: TextRecognizing {
    private(set) var calls = 0
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        calls += 1
        return [RecognizedTextLine(text: "Acme Oat Cereal Honey 12oz", confidence: 1, boundingBox: .zero)]
    }
}
