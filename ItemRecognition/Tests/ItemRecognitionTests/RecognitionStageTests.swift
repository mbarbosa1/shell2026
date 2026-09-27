import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

final class RecognitionStageTests: XCTestCase {
    private let targetID = UUID()
    private let neighborID = UUID()
    private let active = ActivationDecision(state: .active, inactiveReason: nil, clearTemporalCandidates: false)

    // MARK: - One update, one stage

    func testEachStageIsNamedFromTheUpdateAlone() {
        let armed = ActivationDecision(state: .armed,
            inactiveReason: .beforeActivationThreshold(meters: 1, activateAfterMeters: 3), clearTemporalCandidates: false)
        XCTAssertEqual(update(gate: armed, result: result(status: .disabled)).stageOutcome, .init(.activation, "beforeActivationThreshold"))

        XCTAssertEqual(update(result: result(), assessment: assessment(.notLocated)).stageOutcome, .init(.localization, "notLocated"))
        XCTAssertEqual(update(result: result(), assessment: assessment(.focusing)).stageOutcome, .init(.localization, "focusing"))
        XCTAssertEqual(update(result: result(), assessment: assessment(.tooSmall)).stageOutcome, .init(.cropping, "tooSmall"))
        XCTAssertEqual(update(result: result(), readiness: .textTooSmall).stageOutcome, .init(.cropping, "textTooSmall"))

        XCTAssertEqual(update(read: [], result: result()).stageOutcome, .init(.ocrOrClassification, "noWordsRead"))
        XCTAssertEqual(update(read: ["Acme Oat Cereal Chocolate"], result: result(score: 0.6, leading: neighborID)).stageOutcome,
                       .init(.matching, "neighborLeads"))
        XCTAssertEqual(update(read: ["Acme"], result: result(score: 0.2, leading: targetID)).stageOutcome, .init(.matching, "partialTitle"))
        XCTAssertEqual(update(read: ["Nutrition Facts"], result: result()).stageOutcome, .init(.matching, "noTargetWords"))
        XCTAssertEqual(update(read: ["Acme Oat Cereal Honey"], result: result(status: .candidate, score: 1, leading: targetID, passes: true))
                        .stageOutcome, .init(.confirming, "needsMoreFrames"))

        XCTAssertEqual(update(result: visual(.insufficientEvidence, category: nil)).stageOutcome,
                       .init(.ocrOrClassification, "targetClassAbsent"))
        XCTAssertEqual(update(result: visual(.insufficientEvidence, category: "onion", score: 0.2)).stageOutcome,
                       .init(.ocrOrClassification, "belowScoreOrLead"))
        XCTAssertEqual(update(result: visual(.categoryOnly, category: "onion", score: 0.9)).stageOutcome, .init(.matching, "categoryOnly"))

        let asking = update(result: visual(.acceptedCategory, category: "onion", score: 0.9, status: .confirmed), awaiting: true)
        XCTAssertEqual(asking.stageOutcome, .init(.awaitingShopper, "category"))
        XCTAssertNil(update(result: nil).stageOutcome, "no evidence, no stage")
    }

    func testTallyNamesTheBlockerAndFurthestStage() {
        var tally = RecognitionStageTally()
        XCTAssertNil(tally.blocker)
        [RecognitionStageOutcome(.cropping, "textTooSmall"), .init(.cropping, "textTooSmall"), .init(.matching, "neighborLeads"),
         .init(.matching, "neighborLeads"), .init(.localization, "focusing")].forEach { tally.record($0) }
        XCTAssertEqual(tally.frames, 5)
        XCTAssertEqual(tally.blocker, .cropping, "a tie goes to the earlier stage")
        XCTAssertEqual(tally.furthest, .matching)
        XCTAssertEqual(tally.topReasons(1).first?.reason, "cropping/textTooSmall")
        tally.record(.init(.awaitingShopper, "product"))
        XCTAssertEqual(tally.furthest, .awaitingShopper)
        XCTAssertEqual(tally.blocker, .cropping, "success stages are never the blocker")
    }

    func testFramingInstructionsCoverMissingAndCenteredObjects() {
        let missing = FrameAssessment(objectRegion: nil, quality: .notLocated)
        XCTAssertEqual(update(result: result(), assessment: missing).framingInstruction,
                       "Bring the item into view and hold the camera steady")
        let centered = FrameAssessment(objectRegion: CGRect(x: 10, y: 10, width: 30, height: 30), quality: .usable)
        XCTAssertEqual(update(result: result(), assessment: centered).framingInstruction,
                       "Centered. Hold the camera steady")
        XCTAssertNil(update(result: result(), assessment: centered, awaiting: true).framingInstruction)
        let paused = ActivationDecision(state: .suspended, inactiveReason: .externalPause, clearTemporalCandidates: true)
        XCTAssertNil(update(gate: paused, result: result(), assessment: centered).framingInstruction)
    }

    // MARK: - Camera focus reaches the assessor

    func testRefocusingFrameIsNotLocated() async throws {
        let assessment = try await VisionFrameAssessor().assess(image(1, adjustingFocus: true))
        XCTAssertEqual(assessment.quality, .focusing)
        XCTAssertNil(assessment.objectRegion)
        XCTAssertEqual(assessment.guidance, .holdSteady)
        XCTAssertEqual(update(result: result(), assessment: assessment).stageOutcome, .init(.localization, "focusing"))
    }

    // MARK: - Coordinator: lookalikes, product and category

    func testLookalikeReadNamesTheNeighborAndNeverAsks() async throws {
        let session = try await ocrSession(reading: "Acme Oat Cereal Chocolate 12oz")
        let updates = try await run(session)
        XCTAssertFalse(updates.contains(where: \.awaitingVerdict))
        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.result?.leadingItemID, neighborID)
        XCTAssertNil(last.result?.matchedItemID)
        XCTAssertEqual(last.stageOutcome, .init(.matching, "neighborLeads"))
    }

    func testLabelReadConfirmsAtProductLevel() async throws {
        let session = try await ocrSession(reading: "Acme Oat Cereal Honey 12oz")
        let updates = try await run(session)
        let verdict = try XCTUnwrap(updates.first(where: \.awaitingVerdict))
        XCTAssertEqual(verdict.result?.matchLevel, .product)
        XCTAssertEqual(verdict.result?.leadingItemID, targetID)
        XCTAssertEqual(verdict.verdictPrompt, "Is this Acme Oat Cereal Honey 12oz?")
        let accepted = await session.acceptInsight()
        let receipt = try XCTUnwrap(accepted)
        XCTAssertEqual(receipt.matchLevel, .product)
        XCTAssertNil(receipt.category)
    }

    func testProduceConfirmsOnlyAtCategoryLevel() async throws {
        let onion = CatalogItemSnapshot(id: targetID, catalogKey: "onion", displayName: "Fresh Yellow Onion - each", brand: nil,
            normalizedTerms: [], visual: VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: ["onion"],
                                                               allowsConfirmation: true), itemType: "Vegetables")
        let session = try await RecognitionCoordinator(targetID: targetID,
            catalog: StageCatalog(targetID: targetID, candidates: [onion]),
            visualClassifier: try ProduceCategoryClassifier(base: RawLabels()),
            visualPolicy: .appleVisionProduce, assessor: nil)
        let updates = try await run(session)
        let verdict = try XCTUnwrap(updates.first(where: \.awaitingVerdict))
        XCTAssertEqual(verdict.result?.status, .confirmed)
        XCTAssertEqual(updates.map(\.confirmationCount), [1, 2, 3])
        XCTAssertTrue(updates.allSatisfy { $0.requiredConfirmations == 3 })
        XCTAssertEqual(verdict.result?.matchLevel, .category)
        XCTAssertEqual(verdict.verdictPrompt, "This looks like onion. Is it Fresh Yellow Onion - each?")
        XCTAssertNil(verdict.confirmedObservation, "a machine match is not a found item")
        let accepted = await session.acceptInsight()
        let receipt = try XCTUnwrap(accepted)
        XCTAssertEqual(receipt.matchLevel, .category)
        XCTAssertEqual(receipt.category, "onion")
    }

    // MARK: - Helpers

    private func ocrSession(reading text: String) async throws -> RecognitionCoordinator {
        let candidates = [targetID: "Acme Oat Cereal Honey 12oz", neighborID: "Acme Oat Cereal Chocolate 12oz"].map { id, title in
            CatalogItemSnapshot(id: id, catalogKey: id.uuidString, displayName: title, brand: "Acme",
                                normalizedTerms: TextNormalizer().tokens(from: title))
        }
        return try await RecognitionCoordinator(targetID: targetID,
            catalog: StageCatalog(targetID: targetID, candidates: candidates),
            recognizer: Reading(text: text), detector: WholeFrame(), assessor: nil)
    }

    private func run(_ session: RecognitionCoordinator) async throws -> [RecognitionUpdate] {
        let context = RecognitionContext(targetItemID: targetID, landmarkProgress: LandmarkProgressObservation(
            timestamp: 0, passedLandmarkID: "aisle", metersPastLandmark: 5, isReliable: true), externalPause: false)
        var updates: [RecognitionUpdate] = []
        for frame in 1...15 {
            let update = try await session.submit(context, image: image(Double(frame) / 10))
            if update.result != nil { updates.append(update) }
        }
        return updates
    }

    private func image(_ timestamp: Double, adjustingFocus: Bool = false) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!, imageResolution: CGSize(width: 64, height: 48),
                                orientation: .up, isAdjustingFocus: adjustingFocus)
    }

    private func assessment(_ quality: FrameAssessment.Quality) -> FrameAssessment {
        FrameAssessment(objectRegion: quality == .tooSmall ? CGRect(x: 0, y: 0, width: 4, height: 4) : nil, quality: quality)
    }

    private func result(status: ItemRecognitionResult.Status = .noMatch, score: Float = 0,
                        leading: UUID? = nil, passes: Bool = false) -> ItemRecognitionResult {
        ItemRecognitionResult(timestamp: 1, targetItemID: targetID, matchedItemID: status == .confirmed ? targetID : nil,
            normalizedObservedText: [], score: score, status: status, leadingItemID: leading, leadingScore: score, passesPolicy: passes)
    }

    private func visual(_ reason: VisualCatalogMatch.Reason, category: String?, score: Float = 0,
                        status: ItemRecognitionResult.Status = .noMatch) -> ItemRecognitionResult {
        let observation = VisualObservation(timestamp: 1, modelID: ProduceCategoryClassifier.modelID, modelVersion: "v",
            inputRegion: CGRect(x: 0, y: 0, width: 10, height: 10), classifications: [])
        return ItemRecognitionResult(timestamp: 1, targetItemID: targetID, matchedItemID: status == .confirmed ? targetID : nil,
            normalizedObservedText: [], score: score, status: status, evidenceSource: .visual, visualEvidence: observation,
            visualMatchReason: reason, matchedCategory: category)
    }

    private func update(gate: ActivationDecision? = nil, read lines: [String]? = nil, result: ItemRecognitionResult?,
                        assessment: FrameAssessment? = nil, readiness: LabelRegionDetection.Readiness? = nil,
                        awaiting: Bool = false) -> RecognitionUpdate {
        let observation = lines.map { lines in
            ProductTextObservation(timestamp: 1, targetItemID: targetID, boundingBox: .zero, candidates: lines.map {
                RecognizedTextCandidate(rawText: $0, normalizedText: TextNormalizer().normalize($0), confidence: 1, boundingBox: .zero)
            }, side: nil)
        }
        return RecognitionUpdate(gate: gate ?? active, observation: observation, result: result, modeNotice: .ocrOnly,
            awaitingVerdict: awaiting, insight: awaiting ? "Fresh Yellow Onion - each" : nil, assessment: assessment,
            textReadiness: lines == nil ? readiness : .readable, didRunOCR: lines != nil)
    }
}

private struct StageCatalog: CatalogReading {
    let targetID: UUID
    let candidates: [CatalogItemSnapshot]
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { candidates }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetID, landmarkID: "aisle", activateAfterMeters: 3, deactivateAfterMeters: 20)
    }
}

private struct Reading: TextRecognizing {
    let text: String
    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        [RecognizedTextLine(text: text, confidence: 1, boundingBox: .zero)]
    }
}

private struct WholeFrame: LabelRegionDetecting {
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        LabelRegionDetection(crop: CGRect(origin: .zero, size: image.imageResolution))
    }
}

/// Apple-Vision-shaped raw labels: a clear onion with a table behind it.
private struct RawLabels: VisualClassifying {
    func modelInfo() -> VisualModelInfo { VisualModelInfo(id: "fake.local", version: "1", supportedClassIDs: ["onion"]) }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        VisualObservation(timestamp: image.timestamp, modelID: "fake.local", modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: "onion", score: 0.6), .init(identifier: "table", score: 0.7)])
    }
}
