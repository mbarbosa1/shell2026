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
            visualPolicy: .appleVisionProduce)
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
                visualPolicy: .appleVisionProduce)
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

    func testStrongLocalEvidenceNeverCallsCloud() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.95), cloud: cloud)
        let observation = try await classifier.classify(in: image(1), crop: nil)
        XCTAssertEqual(observation.kind, .modelScores)
        XCTAssertEqual(observation.classifications.first?.identifier, "onion")
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
    }

    /// Frames 1–2 weak: on device. Frame 3: Gemini. Frames 4–5: on device.
    /// Frame 6: second and last Gemini call. Frame 7 onward: on device.
    func testWeakLocalEvidenceUsesCloudWithStableModelVersion() async throws {
        let cloud = FakeCloud()
        let local = try ProduceCategoryClassifier(base: FakeBase(score: 0.95), cloud: cloud)
        let weak = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud)
        let strong = try await local.classify(in: image(1), crop: nil)
        let region = CGRect(x: 8, y: 6, width: 32, height: 24)

        for frame in 1...2 {
            let observation = try await weak.classify(in: image(Double(frame)), crop: region)
            XCTAssertEqual(observation.kind, .modelScores, "frame \(frame) stays on device")
            XCTAssertNil(observation.diagnostic, "frame \(frame) is a plain weak frame, not a failure")
        }
        var calls = await cloud.calls
        XCTAssertEqual(calls, 0, "one or two weak frames are normal in video")

        let assisted = try await weak.classify(in: image(3), crop: region)
        XCTAssertEqual(assisted.kind, .cloudSuggestion)
        XCTAssertEqual(assisted.classifications, [.init(identifier: "onion", score: 0.93)])
        XCTAssertEqual(assisted.modelVersion, strong.modelVersion, "Switching source must not reset confirmation")
        XCTAssertEqual(assisted.inputRegion, region)
        let jpeg = await cloud.lastJPEG
        XCTAssertEqual(jpeg?.prefix(2), Data([0xFF, 0xD8]))
        let labels = await cloud.lastLabels
        XCTAssertTrue(labels.contains("onion") && labels.contains("unknown"))

        for frame in 4...5 {
            let observation = try await weak.classify(in: image(Double(frame)), crop: region)
            XCTAssertEqual(observation.kind, .modelScores, "frame \(frame) waits for a new streak")
        }
        calls = await cloud.calls
        XCTAssertEqual(calls, 1)

        let second = try await weak.classify(in: image(6), crop: region)
        XCTAssertEqual(second.kind, .cloudSuggestion, "a second streak earns the last call for this item")
        calls = await cloud.calls
        XCTAssertEqual(calls, 2)

        for frame in 7...12 {
            let observation = try await weak.classify(in: image(Double(frame)), crop: region)
            XCTAssertEqual(observation.kind, .modelScores, "frame \(frame): the item's two calls are used up")
        }
        calls = await cloud.calls
        XCTAssertEqual(calls, 2)
    }

    func testStrongFrameResetsWeakStreak() async throws {
        let cloud = FakeCloud()
        let base = SequenceBase(scores: [0.3, 0.3, 0.95, 0.3, 0.3, 0.3])
        let classifier = try ProduceCategoryClassifier(base: base, cloud: cloud)
        var kinds: [VisualObservation.Kind] = []
        for frame in 1...6 { kinds.append(try await classifier.classify(in: image(Double(frame)), crop: nil).kind) }
        XCTAssertEqual(kinds, [.modelScores, .modelScores, .modelScores, .modelScores, .modelScores, .cloudSuggestion])
        let calls = await cloud.calls
        XCTAssertEqual(calls, 1)
    }

    func testCloudFailureInvalidLabelAndRequestLimitFallBackToLocal() async throws {
        for (cloud, policy) in [(FakeCloud(error: URLError(.timedOut)), CloudAssistPolicy(maximumRequests: 5)),
                                (FakeCloud(label: "yellow_onion"), CloudAssistPolicy(maximumRequests: 5)),
                                (FakeCloud(), CloudAssistPolicy(maximumRequests: 0)),
                                (FakeCloud(), CloudAssistPolicy(maximumRequestsPerItem: 0))] {
            let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud, cloudPolicy: policy)
            for frame in 1...2 {
                let early = try await classifier.classify(in: image(Double(frame)), crop: nil)
                XCTAssertEqual(early.kind, .modelScores)
                XCTAssertNil(early.diagnostic)
            }
            let observation = try await classifier.classify(in: image(3), crop: nil)
            XCTAssertEqual(observation.kind, .modelScores)
            XCTAssertEqual(observation.classifications.first, .init(identifier: "onion", score: 0.3))
            XCTAssertNotNil(observation.diagnostic)
        }
    }

    func testFailedRequestStillCountsTowardTheItemCap() async throws {
        let cloud = FakeCloud(error: URLError(.timedOut))
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.3), cloud: cloud)
        for frame in 1...9 { _ = try await classifier.classify(in: image(Double(frame)), crop: nil) }
        let calls = await cloud.calls
        XCTAssertEqual(calls, 2, "frames 3 and 6 call; frame 9 stays on device")
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

    /// The scheduler processes every 5th active frame, so 50 submissions are 10
    /// processed frames: Gemini answers on the 3rd and 6th, then never again.
    /// Two cloud hits are two accepted observations at most; the weak local frames
    /// between them reset the count, so the item never confirms on the cloud alone.
    func testTwoCloudAnswersAloneDoNotConfirmThroughCoordinator() async throws {
        let cloud = FakeCloud()
        let classifier = try ProduceCategoryClassifier(base: FakeBase(score: 0.2), cloud: cloud)
        let session = try await RecognitionCoordinator(targetID: target, catalog: onionCatalog, visualClassifier: classifier)
        var statuses: [ItemRecognitionResult.Status] = []
        var cloudFrames = 0
        for frame in 1...50 {
            let update = try await session.submit(homeContext, image: image(Double(frame) / 10))
            guard let result = update.result else { continue }
            statuses.append(result.status)
            if update.visualObservation?.kind == .cloudSuggestion {
                cloudFrames += 1
                XCTAssertEqual(result.status, .candidate, "a passing cloud label is evidence, not a confirmation")
                XCTAssertEqual(result.visualMatchReason, .acceptedCategory)
            }
        }
        XCTAssertEqual(cloudFrames, 2)
        let calls = await cloud.calls
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(statuses.contains(.confirmed), "stays a candidate until an on-device frame also passes: \(statuses)")
    }

    /// Weak ×3 (cloud #1), weak ×3 (cloud #2), then two on-device frames that pass:
    /// cloud #2 plus those two make the three accepted observations.
    func testCloudAnswerMixedWithLaterLocalPassesConfirmsThroughCoordinator() async throws {
        let cloud = FakeCloud()
        let base = SequenceBase(scores: [0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.95, 0.95])
        let classifier = try ProduceCategoryClassifier(base: base, cloud: cloud)
        let session = try await RecognitionCoordinator(targetID: target, catalog: onionCatalog, visualClassifier: classifier)
        var latest: RecognitionUpdate?
        var confirmedAt: Int?
        for frame in 1...40 {
            let update = try await session.submit(homeContext, image: image(Double(frame) / 10))
            guard update.result != nil else { continue }
            latest = update
            if update.result?.status == .confirmed, confirmedAt == nil { confirmedAt = frame }
        }
        XCTAssertEqual(confirmedAt, 40, "6 weak processed frames, cloud #2 on the 6th, local passes on the 7th and 8th")
        XCTAssertEqual(latest?.result?.status, .confirmed)
        XCTAssertEqual(latest?.result?.matchedItemID, target)
        XCTAssertEqual(latest?.result?.visualMatchReason, .acceptedCategory)
        XCTAssertEqual(latest?.visualObservation?.kind, .modelScores)
        let calls = await cloud.calls
        XCTAssertEqual(calls, 2)
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

/// Returns `scores` in call order and repeats the last one afterwards.
private actor SequenceBase: VisualClassifying {
    private let scores: [Float]
    private var index = 0
    init(scores: [Float]) { self.scores = scores }
    nonisolated func modelInfo() -> VisualModelInfo { VisualModelInfo(id: "fake.local", version: "1", supportedClassIDs: ["onion"]) }
    func classify(in image: RecognitionImage, crop: CGRect?) -> VisualObservation {
        let score = scores[min(index, scores.count - 1)]
        index += 1
        return VisualObservation(timestamp: image.timestamp, modelID: "fake.local", modelVersion: "1",
            inputRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
            classifications: [.init(identifier: "onion", score: score), .init(identifier: "vegetable", score: 0.99)])
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
