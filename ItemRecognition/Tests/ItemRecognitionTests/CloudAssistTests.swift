import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import ItemRecognition

final class CloudAssistTests: XCTestCase {
    private let target = UUID()

    private func image(_ timestamp: Double, width: Int = 64, height: Int = 48,
                       orientation: CGImagePropertyOrientation = .up) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), 128, CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!,
            imageResolution: CGSize(width: width, height: height), orientation: orientation)
    }

    func testTaxonomyCollapsesVarietiesAndIgnoresParentLabels() throws {
        let taxonomy = try ProduceTaxonomy.bundled()
        let normalized = taxonomy.normalize([
            .init(identifier: "oranges", score: 0.7), .init(identifier: "mandarin", score: 0.8),
            .init(identifier: "fruit", score: 0.99), .init(identifier: "table", score: 0.4),
        ])
        XCTAssertEqual(normalized, [.init(identifier: "orange", score: 0.8), .init(identifier: "unknown", score: 0.4)])
        XCTAssertFalse(taxonomy.identifiers.contains { $0.contains("_onion") }, "No onion varieties in the MVP")
        let background = taxonomy.normalizeWithBackground([
            .init(identifier: "hand", score: 0.5), .init(identifier: "table", score: 0.73), .init(identifier: "onion", score: 0.31),
        ]).backgroundLabel
        XCTAssertEqual(background, "table")
    }

    private func mvpItem(_ id: UUID, _ label: String) -> CatalogItemSnapshot {
        CatalogItemSnapshot(id: id, catalogKey: label, displayName: label, brand: nil, normalizedTerms: [],
            visual: VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: [label],
                                          allowsConfirmation: true))
    }

    private func mvpObservation(_ scores: [String: Float]) -> VisualObservation {
        VisualObservation(timestamp: 1, modelID: ProduceCategoryClassifier.modelID, modelVersion: "v",
            inputRegion: CGRect(x: 0, y: 0, width: 10, height: 10),
            classifications: scores.map { VisualClassification(identifier: $0.key, score: $0.value) })
    }

    func testBackgroundDoesNotCompeteWithAnySelectedProduce() throws {
        for label in ["onion", "apple", "orange", "banana", "grape", "avocado"] {
            let match = try VisualCatalogMatcher().match(
                mvpObservation([label: 0.31, "unknown": 0.73, "potato": 0.04]), targetID: target,
                against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(match.reason, .acceptedCategory, label)
        }
    }

    func testProduceLookalikesAndLowScoresStillBlockEachItem() throws {
        for (label, lookalike) in [("onion", "potato"), ("lime", "lemon"), ("orange", "grapefruit"), ("apple", "tomato")] {
            let close = try VisualCatalogMatcher().match(mvpObservation([label: 0.35, lookalike: 0.30]),
                targetID: target, against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(close.reason, .insufficientEvidence, "\(label) vs \(lookalike)")
            let low = try VisualCatalogMatcher().match(mvpObservation([label: 0.2]),
                targetID: target, against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(low.reason, .insufficientEvidence, "\(label) below threshold")
        }
    }

    func testUnknownStillCompetesForNonTaxonomyModels() throws {
        let item = CatalogItemSnapshot(id: target, catalogKey: "x", displayName: "x", brand: nil, normalizedTerms: [],
            visual: VisualCatalogMetadata(modelID: "custom.detector", classIDs: ["onion"], allowsConfirmation: true))
        let observation = VisualObservation(timestamp: 1, modelID: "custom.detector", modelVersion: "v",
            inputRegion: CGRect(x: 0, y: 0, width: 10, height: 10),
            classifications: [.init(identifier: "onion", score: 0.85), .init(identifier: "unknown", score: 0.9)])
        let match = try VisualCatalogMatcher().match(observation, targetID: target, against: [item], policy: VisualRecognitionPolicy())
        XCTAssertEqual(match.reason, .insufficientEvidence)
    }

    func testEachSelectedItemConfirmsOnDeviceAtAppleVisionThreshold() async throws {
        for label in ["onion", "apple", "orange", "banana"] {
            let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.31, label: label,
                extra: [.init(identifier: "table", score: 0.73), .init(identifier: "potato", score: 0.05)]))
            let session = try await RecognitionCoordinator(targetID: target,
                catalog: SingleItemCatalog(item: mvpItem(target, label)), visualClassifier: classifier,
                visualPolicy: .appleVisionProduce)
            let context = RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
                timestamp: 0, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: false)
            var latest: RecognitionUpdate?
            for frame in 1...15 {
                let update = try await session.submit(context, image: image(Double(frame) / 10))
                if update.result != nil { latest = update }
            }
            XCTAssertEqual(latest?.result?.status, .confirmed, label)
            XCTAssertEqual(latest?.result?.score, 0.31, label)
            XCTAssertEqual(latest?.visualObservation?.backgroundLabel, "table", label)
        }
    }

    func testStrongLocalEvidenceNeverCallsCloud() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.95), cloud: cloud)
        let observation = try await classifier.classify(in: image(1), crop: nil)
        XCTAssertEqual(observation.kind, .modelScores)
        XCTAssertEqual(observation.classifications.first?.identifier, "onion")
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
    }

    func testWeakLocalEvidenceUsesCloudWithStableModelVersion() async throws {
        let cloud = FakeCloud()
        let local = try ProduceCategoryClassifier(base: FakeBase(score: 0.95), cloud: cloud)
        let weak = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud)
        let strong = try await local.classify(in: image(1), crop: nil)
        let assisted = try await weak.classify(in: image(2), crop: CGRect(x: 8, y: 6, width: 32, height: 24))
        XCTAssertEqual(assisted.kind, .cloudSuggestion)
        XCTAssertEqual(assisted.classifications, [.init(identifier: "onion", score: 0.93)])
        XCTAssertEqual(assisted.modelVersion, strong.modelVersion, "Switching source must not reset confirmation")
        XCTAssertEqual(assisted.inputRegion, CGRect(x: 8, y: 6, width: 32, height: 24))
        let jpeg = await cloud.lastJPEG
        XCTAssertEqual(jpeg?.prefix(2), Data([0xFF, 0xD8]))
        let labels = await cloud.lastLabels
        XCTAssertTrue(labels.contains("onion") && labels.contains("unknown"))
    }

    func testCloudFailureInvalidLabelAndRequestLimitFallBackToLocal() async throws {
        for (cloud, limit) in [(FakeCloud(error: URLError(.timedOut)), 5), (FakeCloud(label: "yellow_onion"), 5),
                               (FakeCloud(), 0)] {
            let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud,
                                                           cloudPolicy: CloudAssistPolicy(maximumRequests: limit))
            let observation = try await classifier.classify(in: image(1), crop: nil)
            XCTAssertEqual(observation.kind, .modelScores)
            XCTAssertEqual(observation.classifications.first, .init(identifier: "onion", score: 0.3))
            XCTAssertNotNil(observation.diagnostic)
        }
    }

    func testCategoryModelConfirmsTargetEvenWhenNeighborsShareLabel() throws {
        func apple(_ id: UUID) -> CatalogItemSnapshot {
            CatalogItemSnapshot(id: id, catalogKey: id.uuidString, displayName: "Apple", brand: nil, normalizedTerms: [],
                visual: VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: ["apple"],
                                              allowsConfirmation: true))
        }
        for kind in [VisualObservation.Kind.modelScores, .cloudSuggestion] {
            let observation = VisualObservation(timestamp: 1, modelID: ProduceCategoryClassifier.modelID,
                modelVersion: "v", inputRegion: CGRect(x: 0, y: 0, width: 10, height: 10),
                classifications: [.init(identifier: "apple", score: 0.9)], kind: kind)
            let match = try VisualCatalogMatcher().match(observation, targetID: target,
                against: [apple(target), apple(UUID())], policy: VisualRecognitionPolicy())
            XCTAssertEqual(match.reason, .acceptedCategory)
            XCTAssertTrue(match.accepted)
        }
    }

    func testCloudSuggestionsConfirmThroughCoordinator() async throws {
        let catalog = SingleItemCatalog(item: CatalogItemSnapshot(id: target, catalogKey: "13474244",
            displayName: "Fresh Yellow Onion - each", brand: nil, normalizedTerms: [],
            visual: VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: ["onion"],
                                          allowsConfirmation: true)))
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.2), cloud: FakeCloud())
        let session = try await RecognitionCoordinator(targetID: target, catalog: catalog, visualClassifier: classifier)
        let context = RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
            timestamp: 0, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: false)
        var latest: RecognitionUpdate?
        for frame in 1...15 {
            let update = try await session.submit(context, image: image(Double(frame) / 10))
            if update.result != nil { latest = update }
        }
        XCTAssertEqual(latest?.result?.status, .confirmed)
        XCTAssertEqual(latest?.result?.matchedItemID, target)
        XCTAssertEqual(latest?.result?.visualMatchReason, .acceptedCategory)
        XCTAssertEqual(latest?.visualObservation?.kind, .cloudSuggestion)
    }

    func testEncoderCropsOrientsAndDownscales() throws {
        let source = image(1, width: 320, height: 240, orientation: .right)
        let data = try CloudImageEncoder.jpeg(source, crop: CGRect(x: 40, y: 30, width: 200, height: 100),
                                              maxDimension: 100, context: CIContext())
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil) as? [CFString: Any])
        // `.right` rotates the 200×100 stored crop upright to 100×200, then fits 100 px.
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 50)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 100)
    }
}

private struct SingleItemCatalog: CatalogReading {
    let item: CatalogItemSnapshot
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] { [item] }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        DetectionActivationRuleSnapshot(targetItemID: targetItemID, landmarkID: "home-test",
                                        activateAfterMeters: 3, deactivateAfterMeters: 20)
    }
}

private struct FakeBase: VisualClassifying {
    let score: Float
    var label = "onion"
    var extra: [VisualClassification] = []
    func modelInfo() -> VisualModelInfo { VisualModelInfo(id: "fake.local", version: "1", supportedClassIDs: [label]) }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        VisualObservation(timestamp: image.timestamp, modelID: "fake.local", modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: label, score: score), .init(identifier: "vegetable", score: 0.99)] + extra)
    }
}

private actor FakeCloud: CloudProduceLabeling {
    private let error: Error?
    private let result: String
    private(set) var calls = 0
    private(set) var lastJPEG: Data?
    private(set) var lastLabels: [String] = []
    init(label: String = "onion", error: Error? = nil) { result = label; self.error = error }
    func label(jpeg: Data, allowedLabels: [String]) async throws -> CloudProduceLabel {
        calls += 1; lastJPEG = jpeg; lastLabels = allowedLabels
        if let error { throw error }
        return CloudProduceLabel(label: result, confidence: 0.93, model: "fake-cloud")
    }
}
