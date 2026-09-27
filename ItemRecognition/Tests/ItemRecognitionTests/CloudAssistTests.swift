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

    /// Just above the Apple Vision produce threshold, whatever it is tuned to.
    private var passing: Float { VisualRecognitionPolicy.appleVisionProduce.minimumScore + 0.01 }

    func testBackgroundDoesNotCompeteWithAnySelectedProduce() throws {
        for label in ["onion", "apple", "orange", "banana", "grape", "avocado"] {
            let match = try VisualCatalogMatcher().match(
                mvpObservation([label: passing, "unknown": 0.73, "potato": 0.04]), targetID: target,
                against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(match.reason, .acceptedCategory, label)
        }
    }

    func testProduceLookalikesAndLowScoresStillBlockEachItem() throws {
        for (label, lookalike) in [("onion", "potato"), ("lime", "lemon"), ("orange", "grapefruit"), ("apple", "tomato")] {
            let close = try VisualCatalogMatcher().match(mvpObservation([label: passing + 0.05, lookalike: passing]),
                targetID: target, against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(close.reason, .insufficientEvidence, "\(label) vs \(lookalike)")
            let low = try VisualCatalogMatcher().match(mvpObservation([label: passing - 0.1]),
                targetID: target, against: [mvpItem(target, label)], policy: .appleVisionProduce)
            XCTAssertEqual(low.reason, .insufficientEvidence, "\(label) below threshold")
        }
    }

    func testMatchConfidenceIsRelativeToOtherProduceAndZeroForUnrelatedItems() throws {
        let matcher = VisualCatalogMatcher()
        let policy = VisualRecognitionPolicy(minimumScore: 0.3, minimumMargin: 0.1)
        func confidence(_ scores: [String: Float], kind: VisualObservation.Kind = .modelScores) throws -> Float {
            var observation = mvpObservation(scores)
            if kind == .cloudSuggestion {
                observation = VisualObservation(timestamp: 1, modelID: ProduceCategoryClassifier.modelID, modelVersion: "v",
                    inputRegion: observation.inputRegion, classifications: observation.classifications, kind: kind)
            }
            return try matcher.match(observation, targetID: target, against: [mvpItem(target, "onion")],
                                     policy: policy).confidence
        }
        // The iPhone frame: table in the background does not lower the value.
        XCTAssertEqual(try confidence(["onion": 0.31, "unknown": 0.73, "potato": 0.04]), 0.886, accuracy: 0.001)
        // Cereal box: onion absent or at noise level.
        XCTAssertEqual(try confidence(["unknown": 0.9]), 0)
        XCTAssertEqual(try confidence(["onion": 0.04, "unknown": 0.9]), 0)
        // Lookalike close behind: clearly unsure, but not zero.
        XCTAssertEqual(try confidence(["onion": 0.35, "potato": 0.30]), 0.538, accuracy: 0.001)
        // Weak but unopposed onion: partial strength.
        XCTAssertEqual(try confidence(["onion": 0.15]), 0.5, accuracy: 0.001)
        // Gemini answers carry their own confidence; a different label is 0.
        XCTAssertEqual(try confidence(["onion": 0.9], kind: .cloudSuggestion), 0.9, accuracy: 0.001)
        XCTAssertEqual(try confidence(["potato": 0.9], kind: .cloudSuggestion), 0)
    }

    func testSmootherAveragesRecentFramesAndRestartsAfterGap() {
        var smoother = MatchConfidenceSmoother(window: 3, maximumGap: 2)
        XCTAssertEqual(smoother.add(0.9, at: 1), 0.9, accuracy: 0.001)
        XCTAssertEqual(smoother.add(0.9, at: 1.2), 0.9, accuracy: 0.001)
        XCTAssertEqual(smoother.add(0, at: 1.4), 0.6, accuracy: 0.001, "cereal box appears: decays, no jump")
        XCTAssertEqual(smoother.add(0, at: 1.6), 0.3, accuracy: 0.001)
        XCTAssertEqual(smoother.add(0, at: 1.8), 0, accuracy: 0.001)
        XCTAssertEqual(smoother.add(0.6, at: 5), 0.6, accuracy: 0.001, "gap over 2 s starts over")
        smoother.reset()
        XCTAssertEqual(smoother.add(1, at: 6), 1, accuracy: 0.001)
    }

    func testCoordinatorReportsSmoothedMatchConfidenceAlongsideStatus() async throws {
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: passing,
            extra: [.init(identifier: "table", score: 0.73), .init(identifier: "potato", score: 0.04)]))
        let session = try await RecognitionCoordinator(targetID: target,
            catalog: SingleItemCatalog(item: mvpItem(target, "onion")), visualClassifier: classifier,
            visualPolicy: .appleVisionProduce, assessor: nil)
        let context = RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
            timestamp: 0, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: false)
        var results: [ItemRecognitionResult] = []
        for frame in 1...15 {
            if let result = try await session.submit(context, image: image(Double(frame) / 10)).result { results.append(result) }
        }
        let expected = passing / (passing + 0.04) // full strength, share against potato
        XCTAssertEqual(results.last?.status, .confirmed)
        XCTAssertEqual(results.last?.matchConfidence ?? 0, expected, accuracy: 0.001)
        XCTAssertEqual(results.first?.matchConfidence ?? 0, expected, accuracy: 0.001, "constant input: no ramp needed")
        XCTAssertNotEqual(results.last?.matchConfidence, results.last?.score, "confidence is not the raw label score")
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
            let classifier = try ProduceCategoryClassifier(base: FakeBase(score: passing, label: label,
                extra: [.init(identifier: "table", score: 0.73), .init(identifier: "potato", score: 0.05)]))
            let session = try await RecognitionCoordinator(targetID: target,
                catalog: SingleItemCatalog(item: mvpItem(target, label)), visualClassifier: classifier,
                visualPolicy: .appleVisionProduce, assessor: nil)
            let context = RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
                timestamp: 0, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: false)
            var latest: RecognitionUpdate?
            for frame in 1...15 {
                let update = try await session.submit(context, image: image(Double(frame) / 10))
                if update.result != nil { latest = update }
            }
            XCTAssertEqual(latest?.result?.status, .confirmed, label)
            XCTAssertEqual(latest?.result?.score, passing, label)
            XCTAssertEqual(latest?.visualObservation?.backgroundLabel, "table", label)
        }
    }

    func testAppleVisionWorksAloneFirstThenGeminiTwiceAtMost() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.2), cloud: cloud)
        let region = CGRect(x: 8, y: 6, width: 32, height: 24)
        await classifier.searchStarted(at: 0)
        let early = try await classifier.classify(in: image(4.9), crop: region)
        XCTAssertEqual(early.kind, .modelScores, "Apple Vision alone for the first 5 s at the item")
        var calls = await cloud.calls
        XCTAssertEqual(calls, 0)

        let asked = try await classifier.classify(in: image(5), crop: region)
        XCTAssertEqual(asked.kind, .cloudSuggestion)
        XCTAssertEqual(asked.classifications, [.init(identifier: "onion", score: 0.93)])
        XCTAssertEqual(asked.diagnostic, "Cloud model fake-cloud")
        XCTAssertEqual(asked.inputRegion, region)
        let jpeg = await cloud.lastJPEG
        XCTAssertEqual(jpeg?.prefix(2), Data([0xFF, 0xD8]))
        let labels = await cloud.lastLabels
        XCTAssertTrue(labels.contains("onion") && labels.contains("unknown"))

        let next = try await classifier.classify(in: image(6), crop: region)
        XCTAssertEqual(next.kind, .modelScores, "a Gemini label is never reused for a later frame")
        XCTAssertEqual(next.modelVersion, asked.modelVersion, "switching source must not reset confirmation")
        _ = try await classifier.classify(in: image(10.9), crop: region)
        calls = await cloud.calls
        XCTAssertEqual(calls, 1, "Apple Vision gets another 5 s from the first frame after the answer")
        _ = try await classifier.classify(in: image(11), crop: region)
        _ = try await classifier.classify(in: image(30), crop: region)
        calls = await cloud.calls
        XCTAssertEqual(calls, 2, "two calls per item at most")

        let usage = await classifier.usage()
        XCTAssertEqual(usage.calls, 2)
        XCTAssertEqual(usage.limit, 2)
        XCTAssertNil(usage.secondsUntilCall, "no call remains")
        XCTAssertEqual(usage.lastLabel?.label, "onion")
        XCTAssertNotNil(usage.lastSeconds)
    }

    func testReachingTheItemAgainRestartsTheAppleVisionWindow() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.2), cloud: cloud)
        await classifier.searchStarted(at: 0)
        _ = try await classifier.classify(in: image(4), crop: nil)
        await classifier.searchStarted(at: 8)
        _ = try await classifier.classify(in: image(12), crop: nil)
        var calls = await cloud.calls
        XCTAssertEqual(calls, 0, "only 4 s since the shopper came back")
        let usage = await classifier.usage()
        XCTAssertEqual(usage.secondsUntilCall, 1)
        _ = try await classifier.classify(in: image(13), crop: nil)
        calls = await cloud.calls
        XCTAssertEqual(calls, 1)
    }

    func testInFlightFrameUsesAppleVisionAndNeverReusesTheLabel() async throws {
        let cloud = FakeCloud(delayNanoseconds: 200_000_000)
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud,
                                                       cloudPolicy: CloudAssistPolicy(appleVisionSeconds: 0))
        let region = CGRect(x: 8, y: 6, width: 32, height: 24)
        async let first = classifier.classify(in: image(1), crop: region)
        try await Task.sleep(nanoseconds: 40_000_000)
        let overlapping = try await classifier.classify(in: image(2), crop: region)
        let answered = try await first
        XCTAssertEqual(answered.kind, .cloudSuggestion)
        XCTAssertEqual(overlapping.kind, .modelScores)
        XCTAssertEqual(overlapping.classifications.first, .init(identifier: "onion", score: 0.3))
        let after = try await classifier.classify(in: image(3), crop: region)
        XCTAssertEqual(after.kind, .cloudSuggestion, "with no solo window, the second call runs on the next frame")
        let calls = await cloud.calls
        XCTAssertEqual(calls, 2)
    }

    func testCloudFailureInvalidLabelAndRequestLimitFallBackToLocal() async throws {
        for (cloud, policy) in [(FakeCloud(error: URLError(.timedOut)), CloudAssistPolicy(maximumRequests: 5, appleVisionSeconds: 0)),
                                (FakeCloud(label: "yellow_onion"), CloudAssistPolicy(maximumRequests: 5, appleVisionSeconds: 0))] {
            let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud, cloudPolicy: policy)
            let observation = try await classifier.classify(in: image(1), crop: nil)
            XCTAssertEqual(observation.kind, .modelScores)
            XCTAssertEqual(observation.classifications.first, .init(identifier: "onion", score: 0.3))
            XCTAssertNotNil(observation.diagnostic)
            let usage = await classifier.usage()
            XCTAssertEqual(usage.calls, 1)
            XCTAssertNil(usage.lastLabel)
            XCTAssertNotNil(usage.lastFailure)
        }
        let capped = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: FakeCloud(),
                                                   cloudPolicy: CloudAssistPolicy(maximumRequests: 0, appleVisionSeconds: 0))
        let local = try await capped.classify(in: image(1), crop: nil)
        XCTAssertEqual(local.kind, .modelScores, "no calls allowed")
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

    private var onionCatalog: SingleItemCatalog {
        SingleItemCatalog(item: CatalogItemSnapshot(id: target, catalogKey: "13474244",
            displayName: "Fresh Yellow Onion - each", brand: nil, normalizedTerms: [],
            visual: VisualCatalogMetadata(modelID: ProduceCategoryClassifier.modelID, classIDs: ["onion"],
                                          allowsConfirmation: true)))
    }

    private var homeContext: RecognitionContext {
        RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
            timestamp: 0, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: false)
    }

    /// The scheduler processes every 5th active frame (0.5 s apart here). Detection
    /// turns on at 0.1 s; Apple Vision stays below the produce threshold, so the first
    /// processed frame at least 5 s later asks Gemini, and its passing answer asks the
    /// shopper at once.
    func testGeminiAnswerAsksTheShopperAfterAppleVisionHadItsTime() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.2), cloud: cloud)
        let session = try await RecognitionCoordinator(targetID: target, catalog: onionCatalog,
            visualClassifier: classifier, visualPolicy: .appleVisionProduce, assessor: nil)
        var notices: [(frame: Int, notice: RecognitionModeNotice)] = []
        var confirmedAt: Int?
        var latest: RecognitionUpdate?
        for frame in 1...80 {
            let update = try await session.submit(homeContext, image: image(Double(frame) / 10))
            guard let result = update.result else { continue }
            latest = update
            if confirmedAt == nil { notices.append((frame, update.modeNotice)) }
            if result.status == .confirmed, confirmedAt == nil { confirmedAt = frame }
        }
        XCTAssertEqual(confirmedAt, 55)
        XCTAssertTrue(notices.dropLast().allSatisfy { $0.notice == .appleVision })
        XCTAssertEqual(notices.last?.notice, .cloudAssist)
        XCTAssertEqual(latest?.awaitingVerdict, true)
        XCTAssertEqual(latest?.result?.matchedItemID, target)
        let calls = await cloud.calls
        XCTAssertEqual(calls, 1)
    }

    func testPauseRestartsTheWindowWhenTheShopperIsBackAtTheItem() async throws {
        let classifier = StartRecorder()
        let session = try await RecognitionCoordinator(targetID: target, catalog: onionCatalog,
            visualClassifier: classifier, assessor: nil)
        for frame in 1...10 { _ = try await session.submit(homeContext, image: image(Double(frame) / 10)) }
        _ = try await session.updateContext(RecognitionContext(targetItemID: target, landmarkProgress: LandmarkProgressObservation(
            timestamp: 1.05, passedLandmarkID: "home-test", metersPastLandmark: 5, isReliable: true), externalPause: true))
        for frame in 11...20 { _ = try await session.submit(homeContext, image: image(Double(frame) / 10)) }
        let starts = await classifier.starts
        XCTAssertEqual(starts, [0.1, 1.1])
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
    private let delayNanoseconds: UInt64
    private(set) var calls = 0
    private(set) var lastJPEG: Data?
    private(set) var lastLabels: [String] = []
    init(label: String = "onion", error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        result = label; self.error = error; self.delayNanoseconds = delayNanoseconds
    }
    func label(jpeg: Data, allowedLabels: [String]) async throws -> CloudProduceLabel {
        calls += 1; lastJPEG = jpeg; lastLabels = allowedLabels
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error { throw error }
        return CloudProduceLabel(label: result, confidence: 0.93, model: "fake-cloud")
    }
}

private actor StartRecorder: VisualClassifying {
    private(set) var starts: [TimeInterval] = []
    func modelInfo() -> VisualModelInfo {
        VisualModelInfo(id: ProduceCategoryClassifier.modelID, version: "1", supportedClassIDs: ["onion", "unknown"])
    }
    func searchStarted(at timestamp: TimeInterval) async { starts.append(timestamp) }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        VisualObservation(timestamp: image.timestamp, modelID: ProduceCategoryClassifier.modelID, modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: "onion", score: 0.1)])
    }
}
