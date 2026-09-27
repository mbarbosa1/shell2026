import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

/// The shopper's grocery-list entry is the reference for label text. Titles and
/// item types are records from products.json.
final class GroceryQueryTests: XCTestCase {
    private let targetID = UUID()
    private let neighborID = UUID()

    private func snapshot(_ id: UUID, _ title: String, type: String) -> CatalogItemSnapshot {
        CatalogItemSnapshot(id: id, catalogKey: id.uuidString, displayName: title, brand: nil,
                            normalizedTerms: TextNormalizer().tokens(from: title), itemType: type)
    }
    /// Label lines stacked one line apart: one package.
    private func package(_ texts: [String], top: CGFloat = 0.7, x: CGFloat = 0.3) -> [RecognizedTextCandidate] {
        texts.enumerated().map { row, text in
            RecognizedTextCandidate(rawText: text, normalizedText: TextNormalizer().normalize(text), confidence: 1,
                                    boundingBox: CGRect(x: x, y: top - CGFloat(row) * 0.07, width: 0.4, height: 0.06))
        }
    }
    private func match(_ query: GroceryQuery, _ lines: [RecognizedTextCandidate],
                       _ candidates: [CatalogItemSnapshot]) -> [CatalogMatch] {
        CatalogMatcher().match(ProductTextObservation(timestamp: 1, targetItemID: targetID, boundingBox: .zero,
            candidates: lines, side: nil), against: candidates, targetID: targetID,
            index: ShelfWordIndex(candidates: candidates), query: query)
    }

    func testListWordsMatchApproximately() {
        XCTAssertEqual(CatalogMatcher.similarity("cookies", "cookie"), 1)
        XCTAssertEqual(CatalogMatcher.similarity("cheezit", "cheez-it"), 1)
        XCTAssertEqual(CatalogMatcher.similarity("doritos", "doritas"), 1 - 1 / 7, accuracy: 0.001, "one OCR slip")
        XCTAssertEqual(CatalogMatcher.similarity("doritos", "dorxtas"), 0, "two slips in seven letters is another word")
        XCTAssertEqual(CatalogMatcher.similarity("12oz", "13oz"), 0, "sizes and counts must match exactly")
        XCTAssertEqual(CatalogMatcher.similarity("fat", "fit"), 0, "short words must match exactly")
    }

    func testListWordsOnDifferentPackagesDoNotAddUp() {
        let wanted = GroceryQuery(name: "Cool Ranch", brand: "Doritos").words
        let together = package(["DORITOS", "COOL RANCH"])
        let apart = package(["DORITOS"], top: 0.9, x: 0.05) + package(["COOL RANCH"], top: 0.1, x: 0.6)
        XCTAssertEqual(CatalogMatcher.read(wanted, in: together).score, 1)
        XCTAssertEqual(CatalogMatcher.read(wanted, in: apart).score, 2 / 3, accuracy: 0.001,
                       "the best single package shows two of the three words")
    }

    func testTheShoppersWordsMatchWhereTheLongTitleWouldNot() {
        let eggs = [snapshot(targetID, "Grade A Large Eggs - 12ct - Good & Gather™ (Packaging May Vary)", type: "Eggs"),
                    snapshot(neighborID, "Happy Egg Co. Large Brown Grade A Free Range Eggs - 12ct", type: "Eggs")]
        let carton = package(["Grade A", "LARGE EGGS", "good & gather"])
        let titled = CatalogMatcher().match(ProductTextObservation(timestamp: 1, targetItemID: targetID, boundingBox: .zero,
            candidates: carton, side: nil), against: eggs, targetID: targetID)
        let listed = match(GroceryQuery(name: "large eggs"), carton, eggs)
        XCTAssertLessThan(titled.first { $0.itemID == targetID }!.score, 0.65, "\"Packaging May Vary\" is never printed")
        XCTAssertEqual(listed.first { $0.itemID == targetID }?.score, 1)
        XCTAssertEqual(listed.first { $0.itemID == neighborID }?.score, 0, "other large eggs also fulfil the list")
    }

    func testAProductTheListDoesNotDescribeBlocksTheMatch() {
        let dairy = [snapshot(targetID, "2% Reduced Fat Milk - 1gal - Good & Gather™", type: "Milk and Buttermilk"),
                     snapshot(neighborID, "Half & Half - 32 fl oz (1qt) - Good & Gather™", type: "Cream")]
        let target = match(GroceryQuery(name: "milk"), package(["Half & Half", "Milk and Cream", "good & gather"]), dairy)
            .first { $0.itemID == targetID }
        XCTAssertEqual(target?.score, 0)
        XCTAssertEqual(target?.conflicts, ["half"])
    }

    func testTheLookalikeFlavorDoesNotReachTheListEntry() {
        let chips = [snapshot(targetID, "Doritos Cool Ranch Tortilla Chips - 9.25oz", type: "Chips, Puffs and Pretzels"),
                     snapshot(neighborID, "Doritos Nacho Cheese Tortilla Chips - 9.25oz", type: "Chips, Puffs and Pretzels")]
        let nachoBag = package(["DORITOS", "NACHO CHEESE", "Flavored Tortilla Chips"])
        let named = match(GroceryQuery(name: "Cool Ranch", brand: "Doritos"), nachoBag, chips).first { $0.itemID == targetID }
        XCTAssertLessThan(named?.score ?? 1, RecognitionPolicy().minimumQueryScore)
        let brandOnly = match(GroceryQuery(name: "Doritos"), nachoBag, chips)
        XCTAssertEqual(brandOnly.first { $0.itemID == targetID }?.score, 1, "any flavor fulfils a list that says only Doritos")
    }

    func testCoordinatorAsksWithTheListEntry() async throws {
        let dairy = [snapshot(targetID, "2% Reduced Fat Milk - 1gal - Good & Gather™", type: "Milk and Buttermilk"),
                     snapshot(neighborID, "Half & Half - 32 fl oz (1qt) - Good & Gather™", type: "Cream")]
        let session = try await RecognitionCoordinator(targetID: targetID,
            catalog: ListCatalog(targetID: targetID, candidates: dairy),
            recognizer: ListRecognizer(lines: package(["2%", "REDUCED FAT", "MILK"])), detector: ListRegion(),
            assessor: nil, query: GroceryQuery(name: "milk", label: "2%"))
        var update: RecognitionUpdate?
        for index in 1...5 { update = try await session.submit(context(), image: image(Double(index) / 10)) }
        XCTAssertEqual(update?.awaitingVerdict, true)
        XCTAssertEqual(update?.verdictPrompt, "Is this 2% milk?")
        let accepted = await session.acceptInsight()
        XCTAssertEqual(accepted?.itemID, targetID)
    }

    private func context() -> RecognitionContext {
        RecognitionContext(targetItemID: targetID, landmarkProgress: LandmarkProgressObservation(timestamp: 0,
            passedLandmarkID: "aisle", metersPastLandmark: 5, isReliable: true), externalPause: false)
    }
    private func image(_ timestamp: Double) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!, imageResolution: CGSize(width: 64, height: 48), orientation: .up)
    }
}

private struct ListCatalog: CatalogReading {
    let targetID: UUID
    let candidates: [CatalogItemSnapshot]
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { candidates }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetID, landmarkID: "aisle", activateAfterMeters: 3, deactivateAfterMeters: 20)
    }
}
private struct ListRegion: LabelRegionDetecting {
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        LabelRegionDetection(crop: CGRect(origin: .zero, size: image.imageResolution))
    }
}
private struct ListRecognizer: TextRecognizing {
    let lines: [RecognizedTextCandidate]
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        lines.map { RecognizedTextLine(text: $0.rawText, confidence: $0.confidence, boundingBox: $0.boundingBox) }
    }
}
