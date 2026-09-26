import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

// MARK: - Fakes

/// Same in-memory stand-in for the database branch used by the gate tests.
private actor SchedulerTestCatalog: CatalogReading {
    private let rules: [UUID: DetectionActivationRuleSnapshot]

    init(rules: [DetectionActivationRuleSnapshot]) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.targetItemID, $0) })
    }

    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        XCTFail("catalogCandidates must not be called by the extraction slice")
        return []
    }

    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        rules[targetItemID]
    }
}

/// Fake OCR engine. Counts calls, returns configured lines, and can hold a
/// request open so the scheduler's pending slot can be observed.
private actor FakeRecognizer: TextRecognizing {
    private(set) var callCount = 0
    private(set) var lastRegionOfInterest: CGRect??
    var lines: [RecognizedTextLine] = []
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recognizeText(in image: RecognitionImage, regionOfInterest: CGRect?) async throws -> [RecognizedTextLine] {
        callCount += 1
        lastRegionOfInterest = .some(regionOfInterest)
        if blocked {
            await withCheckedContinuation { waiters.append($0) }
        }
        return lines
    }

    func setLines(_ lines: [RecognizedTextLine]) { self.lines = lines }
    func block() { blocked = true }

    func release() {
        blocked = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

// MARK: - Tests

final class TextExtractionSchedulerTests: XCTestCase {

    private let cerealID = UUID()
    private let landmark = "aisle_25_top"

    private func cerealRule(isInStore: Bool = true, side: ShelfSide? = .left) -> DetectionActivationRuleSnapshot {
        DetectionActivationRuleSnapshot(
            targetItemID: cerealID,
            landmarkID: landmark,
            activateAfterMeters: 3.0,
            deactivateAfterMeters: 20.0,
            side: side,
            isInStore: isInStore
        )
    }

    private func makeScheduler(
        rules: [DetectionActivationRuleSnapshot]? = nil,
        stride: Int = 5
    ) -> (TextExtractionScheduler, FakeRecognizer, ActivationGate) {
        let catalog = SchedulerTestCatalog(rules: rules ?? [cerealRule()])
        let gate = ActivationGate(catalog: catalog)
        let recognizer = FakeRecognizer()
        let scheduler = TextExtractionScheduler(gate: gate, recognizer: recognizer, frameStride: stride)
        return (scheduler, recognizer, gate)
    }

    private func context(
        landmark: String? = "aisle_25_top",
        meters: Double? = 10.0,
        reliable: Bool = true,
        pause: Bool = false
    ) -> RecognitionContext {
        RecognitionContext(
            targetItemID: cerealID,
            landmarkProgress: LandmarkProgressObservation(
                timestamp: 100,
                passedLandmarkID: landmark,
                metersPastLandmark: meters,
                isReliable: reliable
            ),
            externalPause: pause
        )
    }

    private func makeBuffer(width: Int = 64, height: Int = 48) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        precondition(status == kCVReturnSuccess, "pixel buffer creation failed: \(status)")
        return buffer!
    }

    private func image(
        width: Int = 64,
        height: Int = 48,
        declared: CGSize? = nil,
        timestamp: TimeInterval = 7
    ) -> RecognitionImage {
        RecognitionImage(
            timestamp: timestamp,
            pixelBuffer: makeBuffer(width: width, height: height),
            imageResolution: declared ?? CGSize(width: width, height: height),
            orientation: .up
        )
    }

    /// Submit `count` frames sequentially with the same context.
    @discardableResult
    private func submitFrames(
        _ count: Int,
        to scheduler: TextExtractionScheduler,
        context: RecognitionContext
    ) async throws -> [ProductTextObservation?] {
        var results: [ProductTextObservation?] = []
        for _ in 0..<count {
            results.append(try await scheduler.submit(context, image: image()))
        }
        return results
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 2,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting: \(message)", file: file, line: line)
    }

    // MARK: - Gate off means the recognizer is never called

    func testRecognizerNotCalledWhileGateIsOff() async throws {
        let notInStore = cerealRule(isInStore: false)

        let cases: [(String, [DetectionActivationRuleSnapshot], RecognitionContext, DetectionGateState)] = [
            ("waitingForLandmark", [cerealRule()], context(landmark: "aisle_24_top", meters: 10.0), .waitingForLandmark),
            ("armed", [cerealRule()], context(meters: 2.4), .armed),
            ("suspended", [cerealRule()], context(meters: 10.0, reliable: false), .suspended),
            ("thresholdPassed", [cerealRule()], context(meters: 25.0), .thresholdPassed),
            ("itemNotInStore", [notInStore], context(meters: 10.0), .itemNotInStore),
        ]

        for (name, rules, ctx, expectedState) in cases {
            let (scheduler, recognizer, gate) = makeScheduler(rules: rules)

            // Twice the stride so a stride-eligible frame would have come up.
            let results = try await submitFrames(10, to: scheduler, context: ctx)

            let calls = await recognizer.callCount
            let state = await gate.currentState
            XCTAssertEqual(calls, 0, "\(name): recognizer must not run")
            XCTAssertEqual(state, expectedState, "\(name)")
            XCTAssertTrue(results.allSatisfy { $0 == nil }, "\(name): every submit returns nil")
        }
    }

    // MARK: - Stride and the observation

    func testFirstFourFramesSkipAndFifthRunsOCR() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)
        await recognizer.setLines([
            RecognizedTextLine(text: "Honey Nut CHEERIOS", confidence: 0.92, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1)),
            RecognizedTextLine(text: "12 OZ", confidence: 0.80, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)),
        ])

        let firstFour = try await submitFrames(4, to: scheduler, context: context())
        XCTAssertTrue(firstFour.allSatisfy { $0 == nil })
        var calls = await recognizer.callCount
        XCTAssertEqual(calls, 0)

        let fifth = try await scheduler.submit(context(), image: image(timestamp: 42))
        calls = await recognizer.callCount
        XCTAssertEqual(calls, 1)

        let observation = try XCTUnwrap(fifth)
        XCTAssertEqual(observation.targetItemID, cerealID)
        XCTAssertEqual(observation.timestamp, 42)
        XCTAssertEqual(observation.side, .left)
        XCTAssertEqual(observation.boundingBox, CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertEqual(observation.candidates.count, 2)
        XCTAssertEqual(observation.candidates[0].rawText, "Honey Nut CHEERIOS")
        XCTAssertEqual(observation.candidates[0].normalizedText, "honey nut cheerios")
        XCTAssertEqual(observation.candidates[0].confidence, 0.92)
        XCTAssertEqual(observation.candidates[1].normalizedText, "12oz")

        let roi = await recognizer.lastRegionOfInterest
        XCTAssertEqual(roi, .some(nil), "full frame uses Vision's default region")
    }

    func testEveryStrideThFrameRunsWhileActive() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)

        try await submitFrames(15, to: scheduler, context: context())

        let calls = await recognizer.callCount
        XCTAssertEqual(calls, 3, "frames 5, 10, and 15")
    }

    func testStrideCounterResetsWhenGateLeavesActive() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)

        try await submitFrames(4, to: scheduler, context: context())
        _ = try await scheduler.submit(context(meters: 2.0), image: image()) // armed
        try await submitFrames(4, to: scheduler, context: context())

        var calls = await recognizer.callCount
        XCTAssertEqual(calls, 0, "counter restarted after the armed frame")

        _ = try await scheduler.submit(context(), image: image())
        calls = await recognizer.callCount
        XCTAssertEqual(calls, 1)
    }

    func testStrideIsClampedToNotionRange() {
        let (low, _, _) = makeScheduler(stride: 1)
        let (high, _, _) = makeScheduler(stride: 60)
        let (mid, _, _) = makeScheduler(stride: 7)

        XCTAssertEqual(low.frameStride, 5)
        XCTAssertEqual(high.frameStride, 10)
        XCTAssertEqual(mid.frameStride, 7)
    }

    func testSideIsNilWhenRuleHasNone() async throws {
        let (scheduler, _, _) = makeScheduler(rules: [cerealRule(side: nil)])

        try await submitFrames(4, to: scheduler, context: context())
        let observation = try await scheduler.submit(context(), image: image())

        XCTAssertNil(try XCTUnwrap(observation).side)
    }

    func testCropIsForwardedAsNormalizedRegionAndReportedAsBox() async throws {
        let (scheduler, recognizer, _) = makeScheduler()
        let crop = CGRect(x: 16, y: 12, width: 32, height: 24) // inside 64x48

        try await submitFrames(4, to: scheduler, context: context())
        let observation = try await scheduler.submit(context(), image: image(), crop: crop)

        XCTAssertEqual(try XCTUnwrap(observation).boundingBox, crop)
        let roi = await recognizer.lastRegionOfInterest
        let expected = try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: CGSize(width: 64, height: 48))
        XCTAssertEqual(roi, .some(expected))
    }

    func testOCRWithNoTextReturnsObservationWithNoCandidates() async throws {
        let (scheduler, _, _) = makeScheduler()

        try await submitFrames(4, to: scheduler, context: context())
        let observation = try await scheduler.submit(context(), image: image())

        XCTAssertEqual(try XCTUnwrap(observation).candidates, [])
    }

    // MARK: - Latest frame wins

    func testNewerEligibleFrameReplacesPendingFrame() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)
        await recognizer.block()

        // Frames 1-4 skip; frame 5 goes in flight and blocks inside the recognizer.
        try await submitFrames(4, to: scheduler, context: context())
        let inFlight = Task { try await scheduler.submit(self.context(), image: self.image(timestamp: 5)) }
        await waitUntil({ await recognizer.callCount == 1 }, "frame 5 in flight")

        // Frames 6-9 skip; frame 10 becomes the single pending frame.
        try await submitFrames(4, to: scheduler, context: context())
        let firstPending = Task { try await scheduler.submit(self.context(), image: self.image(timestamp: 10)) }
        await waitUntil({ await scheduler.hasPendingFrame }, "frame 10 pending")

        // Frames 11-14 skip; frame 15 replaces frame 10.
        try await submitFrames(4, to: scheduler, context: context())
        let secondPending = Task { try await scheduler.submit(self.context(), image: self.image(timestamp: 15)) }

        let replaced = try await firstPending.value
        XCTAssertNil(replaced, "the replaced frame's submit returns nil")
        var calls = await recognizer.callCount
        XCTAssertEqual(calls, 1, "frame 10 never reached the recognizer")

        await recognizer.release()

        let first = try await inFlight.value
        let latest = try await secondPending.value
        XCTAssertEqual(try XCTUnwrap(first).timestamp, 5)
        XCTAssertEqual(try XCTUnwrap(latest).timestamp, 15)
        calls = await recognizer.callCount
        XCTAssertEqual(calls, 2, "only frames 5 and 15 ran")

        let stillPending = await scheduler.hasPendingFrame
        let stillInFlight = await scheduler.isRequestInFlight
        XCTAssertFalse(stillPending)
        XCTAssertFalse(stillInFlight)
    }

    // MARK: - Invalid images

    func testResolutionMismatchThrowsAndLeavesGateUnchanged() async throws {
        let (scheduler, recognizer, gate) = makeScheduler()
        let bad = image(width: 64, height: 48, declared: CGSize(width: 100, height: 100))

        do {
            _ = try await scheduler.submit(context(), image: bad)
            XCTFail("expected invalidImage")
        } catch let error as TextExtractionError {
            XCTAssertEqual(
                error,
                .invalidImage(.resolutionMismatch(
                    declared: CGSize(width: 100, height: 100),
                    buffer: CGSize(width: 64, height: 48)
                ))
            )
        }

        let state = await gate.currentState
        let last = await gate.lastDecision
        let calls = await recognizer.callCount
        XCTAssertEqual(state, .waitingForLandmark, "gate untouched by the bad frame")
        XCTAssertNil(last, "gate never evaluated")
        XCTAssertEqual(calls, 0)
    }

    func testZeroDeclaredDimensionThrowsInvalidImage() async throws {
        let (scheduler, _, _) = makeScheduler()
        let bad = image(declared: CGSize(width: 0, height: 48))

        do {
            _ = try await scheduler.submit(context(), image: bad)
            XCTFail("expected invalidImage")
        } catch let error as TextExtractionError {
            XCTAssertEqual(error, .invalidImage(.zeroDimension))
        }
    }

    func testCropOutsideImageThrowsBeforeGateEvaluation() async throws {
        let (scheduler, _, gate) = makeScheduler()
        let crop = CGRect(x: 40, y: 10, width: 40, height: 10) // maxX 80 > 64

        do {
            _ = try await scheduler.submit(context(), image: image(), crop: crop)
            XCTFail("expected invalidImage")
        } catch let error as TextExtractionError {
            XCTAssertEqual(
                error,
                .invalidImage(.cropOutsideImage(crop: crop, image: CGSize(width: 64, height: 48)))
            )
        }

        let last = await gate.lastDecision
        XCTAssertNil(last)
    }

    // MARK: - Pause

    func testExternalPauseAfterActiveDoesNotCallRecognizer() async throws {
        let (scheduler, recognizer, gate) = makeScheduler(stride: 5)

        try await submitFrames(5, to: scheduler, context: context())
        var calls = await recognizer.callCount
        XCTAssertEqual(calls, 1)

        // Ten paused frames: two would have been stride-eligible.
        let paused = try await submitFrames(10, to: scheduler, context: context(pause: true))

        calls = await recognizer.callCount
        let state = await gate.currentState
        XCTAssertEqual(calls, 1, "no OCR while paused")
        XCTAssertEqual(state, .suspended)
        XCTAssertTrue(paused.allSatisfy { $0 == nil })
    }

    func testPauseDiscardsPendingFrameAndInFlightResult() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)
        await recognizer.block()

        try await submitFrames(4, to: scheduler, context: context())
        let inFlight = Task { try await scheduler.submit(self.context(), image: self.image(timestamp: 5)) }
        await waitUntil({ await recognizer.callCount == 1 }, "frame 5 in flight")

        try await submitFrames(4, to: scheduler, context: context())
        let pendingFrame = Task { try await scheduler.submit(self.context(), image: self.image(timestamp: 10)) }
        await waitUntil({ await scheduler.hasPendingFrame }, "frame 10 pending")

        // Safety pause arrives while OCR is running.
        let pausedResult = try await scheduler.submit(context(pause: true), image: image())
        XCTAssertNil(pausedResult)

        let discardedPending = try await pendingFrame.value
        XCTAssertNil(discardedPending, "pending frame dropped by the pause")

        await recognizer.release()
        let discardedInFlight = try await inFlight.value
        XCTAssertNil(discardedInFlight, "in-flight result discarded because the gate is no longer active")

        let calls = await recognizer.callCount
        XCTAssertEqual(calls, 1)
    }

    func testResumeAfterPauseRequiresFreshStride() async throws {
        let (scheduler, recognizer, _) = makeScheduler(stride: 5)

        try await submitFrames(5, to: scheduler, context: context())
        _ = try await scheduler.submit(context(pause: true), image: image())
        try await submitFrames(4, to: scheduler, context: context())

        var calls = await recognizer.callCount
        XCTAssertEqual(calls, 1, "four frames after resume are not yet eligible")

        _ = try await scheduler.submit(context(), image: image())
        calls = await recognizer.callCount
        XCTAssertEqual(calls, 2)
    }
}
