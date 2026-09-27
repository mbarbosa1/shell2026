import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

/// Milk beside other items: each object's text is scored alone and the catalog
/// picks the target's box. Titles and item types are the aisle G44 records from
/// products.json; water is not in the catalog.
final class ObjectTextMatchTests: XCTestCase {
    private let milkID = UUID()
    private let halfID = UUID()
    // Normalized lower-left boxes in the oriented image, the space OCR lines use.
    private let milkBox = CGRect(x: 0.05, y: 0.10, width: 0.40, height: 0.80)
    private let otherBox = CGRect(x: 0.55, y: 0.10, width: 0.40, height: 0.80)

    private var catalog: [CatalogItemSnapshot] {
        [snapshot(milkID, "2% Reduced Fat Milk - 1gal - Good & Gather™", type: "Milk and Buttermilk"),
         snapshot(halfID, "Half & Half - 32 fl oz (1qt) - Good & Gather™", type: "Cream")]
    }
    private func snapshot(_ id: UUID, _ title: String, type: String) -> CatalogItemSnapshot {
        CatalogItemSnapshot(id: id, catalogKey: id.uuidString, displayName: title, brand: nil,
                            normalizedTerms: TextNormalizer().tokens(from: title), itemType: type)
    }
    /// Label lines stacked in one column starting at `x`, top line first.
    private func label(_ texts: [String], x: CGFloat) -> [(String, CGRect)] {
        texts.enumerated().map { row, text in (text, CGRect(x: x, y: 0.62 - CGFloat(row) * 0.07, width: 0.30, height: 0.06)) }
    }
    private var milkLabel: [(String, CGRect)] { label(["2%", "Reduced Fat Milk", "Good & Gather"], x: 0.10) }
    private var waterLabel: [(String, CGRect)] { label(["Purified", "Drinking Water", "1 gal"], x: 0.60) }
    private var halfLabel: [(String, CGRect)] { label(["Half & Half", "Milk and Cream", "Good & Gather"], x: 0.60) }

    private func observation(_ rows: [(String, CGRect)]) -> ProductTextObservation {
        ProductTextObservation(timestamp: 1, targetItemID: milkID, boundingBox: .zero,
            candidates: rows.map { text, box in
                RecognizedTextCandidate(rawText: text, normalizedText: TextNormalizer().normalize(text),
                                        confidence: 1, boundingBox: box)
            }, side: nil)
    }
    private func pick(_ rows: [(String, CGRect)], boxes: [CGRect]) -> ObjectTextMatch? {
        CatalogMatcher().matchPerObject(observation(rows), objectBoxes: boxes, against: catalog,
                                        targetID: milkID, index: ShelfWordIndex(candidates: catalog))
    }

    // MARK: - Grouping and choice

    func testLinesGoToTheSmallestObjectContainingTheirCentre() {
        let outer = CGRect(x: 0, y: 0, width: 1, height: 1)
        let inner = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let groups = CatalogMatcher.group(observation([
            ("on inner", CGRect(x: 0.15, y: 0.2, width: 0.1, height: 0.05)),
            ("on outer", CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.05)),
        ]), by: [outer, inner, CGRect(x: 2, y: 2, width: 1, height: 1)])
        XCTAssertEqual(groups.map { $0.observation.candidates.map(\.rawText) }, [["on outer"], ["on inner"], []])
    }

    func testMilkBesideWaterReturnsOnlyTheMilkBox() throws {
        let picked = try XCTUnwrap(pick(milkLabel + waterLabel, boxes: [milkBox, otherBox]))
        XCTAssertEqual(picked.objectBox, milkBox)
        XCTAssertEqual(picked.matches.first?.itemID, milkID)
        XCTAssertGreaterThan(picked.matches.first?.score ?? 0, 0)
        XCTAssertFalse(picked.observation.candidates.contains { $0.rawText.contains("Water") },
                       "the water bottle's words never reach the milk's evidence")
    }

    func testMilkBesideHalfAndHalfPicksTheMilkBox() throws {
        // Both cartons print "milk"; only the jug's own lines may score for the target.
        let picked = try XCTUnwrap(pick(milkLabel + halfLabel, boxes: [otherBox, milkBox]))
        XCTAssertEqual(picked.objectBox, milkBox)
        let milk = try XCTUnwrap(picked.matches.first { $0.itemID == milkID })
        XCTAssertGreaterThanOrEqual(milk.score, RecognitionPolicy().minimumScore)
        XCTAssertTrue(milk.conflicts.isEmpty)
    }

    func testTwoFacingsOfTheTargetPickTheBoxNearerTheCentre() {
        let centred = CGRect(x: 0.35, y: 0.10, width: 0.30, height: 0.80)
        let edge = CGRect(x: 0.00, y: 0.10, width: 0.30, height: 0.80)
        let rows = label(["2%", "Reduced Fat Milk", "Good & Gather"], x: 0.02)
            + label(["2%", "Reduced Fat Milk", "Good & Gather"], x: 0.37)
        XCTAssertEqual(pick(rows, boxes: [edge, centred])?.objectBox, centred)
    }

    func testNoObjectCarryingTheTargetsTextPicksNothing() {
        XCTAssertNil(pick(waterLabel, boxes: [milkBox, otherBox]))
        XCTAssertNil(pick(halfLabel, boxes: [milkBox, otherBox]))
    }

    // MARK: - Geometry

    func testOCRBoxesInsideARegionMapBackToTheWholeImage() {
        // Measured with VNRecognizeTextRequest: "MILK" at x 0.664 in the full image
        // was reported at x 0.322 inside a region starting at 0.5 with width 0.5.
        let roi = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let mapped = VisionTextRecognizer.imageBox(CGRect(x: 0.3217, y: 0.5225, width: 0.2483, height: 0.1225), regionOfInterest: roi)
        XCTAssertEqual(mapped.minX, 0.6608, accuracy: 0.001)
        XCTAssertEqual(mapped.minY, 0.7612, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 0.1242, accuracy: 0.001)
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(VisionTextRecognizer.imageBox(box, regionOfInterest: nil), box)
    }

    func testMaskSpecksBesideARealItemAreNotSecondObjects() {
        let item = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        let speck = CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)
        XCTAssertEqual(VisionFrameAssessor.droppingSpecks([item, speck]), [item])
        XCTAssertEqual(VisionFrameAssessor.droppingSpecks([speck]), [speck], "a lone small item still asks to move forward")
    }

    func testSeveralObjectsAreUsableWhenAnyOneIsReadable() {
        let usable = CGRect(x: 0.1, y: 0.1, width: 0.35, height: 0.6)
        let clipped = CGRect(x: 0.6, y: 0.0, width: 0.4, height: 0.9)
        let tiny = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        XCTAssertEqual(VisionFrameAssessor.multipleObjectsQuality([usable, clipped]), .usable)
        XCTAssertEqual(VisionFrameAssessor.multipleObjectsQuality([tiny, CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)]), .tooSmall)
    }

    // MARK: - Coordinator

    func testCoordinatorConfirmsTheMilkAndReportsItsBox() async throws {
        let session = try await RecognitionCoordinator(targetID: milkID,
            catalog: FixedCatalog(targetID: milkID, candidates: catalog),
            recognizer: SceneRecognizer(rows: milkLabel + waterLabel), detector: WholeFrame(),
            policy: RecognitionPolicy(requiredObservations: 3), // candidate frames first, so the hint is visible
            assessor: TwoObjects(boxes: [otherBox, milkBox]))
        var processed: [RecognitionUpdate] = []
        for index in 1...15 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.result != nil { processed.append(update) }
        }
        let verdict = try XCTUnwrap(processed.last)
        XCTAssertEqual(verdict.result?.status, .confirmed)
        XCTAssertTrue(verdict.awaitingVerdict)
        XCTAssertEqual(verdict.insight, "2% Reduced Fat Milk - 1gal - Good & Gather™")
        XCTAssertEqual(verdict.observation?.candidates.map(\.rawText), milkLabel.map(\.0))
        XCTAssertEqual(processed.first?.guidance, .moveLeft, "the milk sits left of centre, so steer toward it")
        // Pixel box of the milk in the 64 × 48 frame (top-left origin).
        let focused = try XCTUnwrap(verdict.focusedObject)
        XCTAssertEqual(focused.minX, 3.2, accuracy: 0.01)
        XCTAssertEqual(focused.minY, 4.8, accuracy: 0.01)
        XCTAssertEqual(focused.width, 25.6, accuracy: 0.01)
        XCTAssertEqual(focused.height, 38.4, accuracy: 0.01)
        let accepted = await session.acceptInsight()
        XCTAssertEqual(accepted?.itemID, milkID)
    }

    func testCoordinatorDoesNotMatchWhenOnlyTheWaterHasText() async throws {
        let session = try await RecognitionCoordinator(targetID: milkID,
            catalog: FixedCatalog(targetID: milkID, candidates: catalog),
            recognizer: SceneRecognizer(rows: waterLabel), detector: WholeFrame(),
            assessor: TwoObjects(boxes: [milkBox, otherBox]))
        var last: RecognitionUpdate?
        for index in 1...15 {
            let update = try await session.submit(context(), image: image(Double(index) / 10))
            if update.result != nil { last = update }
        }
        XCTAssertEqual(last?.result?.status, .noMatch)
        XCTAssertNil(last?.focusedObject)
        XCTAssertNotEqual(last?.guidance, .moveRight, "no left/right advice before the catalog picks a box")
    }

    func testAppearancePathStillWantsOneItemInView() async throws {
        let vision = CountingVision()
        let apple = CatalogItemSnapshot(id: milkID, catalogKey: "apple", displayName: "Gala Apple", brand: nil,
            normalizedTerms: [], visual: VisualCatalogMetadata(modelID: "counting.vision", classIDs: ["apple"],
                allowsConfirmation: true), itemType: "Fruit")
        let session = try await RecognitionCoordinator(targetID: milkID,
            catalog: FixedCatalog(targetID: milkID, candidates: [apple]),
            recognizer: SceneRecognizer(rows: []), visualClassifier: vision,
            assessor: TwoObjects(boxes: [milkBox, otherBox]))
        var last: RecognitionUpdate?
        for index in 1...5 { last = try await session.submit(context(), image: image(Double(index) / 10)) }
        XCTAssertEqual(last?.assessment?.quality, .multipleObjects)
        let calls = await vision.calls
        XCTAssertEqual(calls, 0)
    }

    private func context() -> RecognitionContext {
        RecognitionContext(targetItemID: milkID, landmarkProgress: LandmarkProgressObservation(timestamp: 0,
            passedLandmarkID: "aisle", metersPastLandmark: 5, isReliable: true), externalPause: false)
    }
    private func image(_ timestamp: Double) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!, imageResolution: CGSize(width: 64, height: 48), orientation: .up)
    }
}

private struct FixedCatalog: CatalogReading {
    let targetID: UUID
    let candidates: [CatalogItemSnapshot]
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { candidates }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetID, landmarkID: "aisle", activateAfterMeters: 3, deactivateAfterMeters: 20)
    }
}
/// Two separate foreground objects, as the instance mask reports milk beside water.
private struct TwoObjects: FrameAssessing {
    let boxes: [CGRect]
    func assess(_ image: RecognitionImage) async throws -> FrameAssessment {
        try VisionFrameAssessor.multipleObjects(boxes, image: image, continuityLost: false)
    }
}
private struct WholeFrame: LabelRegionDetecting {
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        LabelRegionDetection(crop: CGRect(origin: .zero, size: image.imageResolution))
    }
}
/// One OCR pass over the scene, line boxes in whole-image coordinates.
private struct SceneRecognizer: TextRecognizing {
    let rows: [(String, CGRect)]
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        rows.map { RecognizedTextLine(text: $0.0, confidence: 1, boundingBox: $0.1) }
    }
}
private actor CountingVision: VisualClassifying {
    private(set) var calls = 0
    func modelInfo() -> VisualModelInfo {
        VisualModelInfo(id: "counting.vision", version: "1", supportedClassIDs: ["apple", "unknown"])
    }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        calls += 1
        return VisualObservation(timestamp: image.timestamp, modelID: "counting.vision", modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: "apple", score: 0.95)])
    }
}
