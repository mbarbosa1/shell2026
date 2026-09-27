import CoreGraphics
import CoreVideo
import XCTest
@testable import ItemRecognition

final class SelfCheckoutEvidenceTests: XCTestCase {
    private func line(_ text: String, confidence: Float = 0.9,
                      box: CGRect = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.05)) -> RecognizedTextLine {
        RecognizedTextLine(text: text, confidence: confidence, boundingBox: box)
    }

    func testNormalizingJoinsSpellingsOfSelfCheckout() {
        XCTAssertEqual(SelfCheckoutEvidence.normalize("SELF-CHECKOUT"), "self checkout")
        XCTAssertEqual(SelfCheckoutEvidence.normalize("  Self  Check-Out! "), "self check out")
    }

    func testASignNamingItIsEnough() throws {
        let decision = try XCTUnwrap(SelfCheckoutEvidence.decide(lines: [line("SELF CHECKOUT")], labels: []))
        XCTAssertEqual(decision.confidence, SelfCheckoutEvidence.namingConfidence)
        XCTAssertEqual(decision.evidence, "Read “SELF CHECKOUT”")
    }

    func testScreenTextNeedsASupportingLabel() throws {
        let screen = [line("Scan your first item")]
        XCTAssertNil(SelfCheckoutEvidence.decide(lines: screen, labels: []))
        XCTAssertNil(SelfCheckoutEvidence.decide(lines: screen, labels: [VisualClassification(identifier: "atm", score: 0.1)]))
        let decision = try XCTUnwrap(SelfCheckoutEvidence.decide(
            lines: screen, labels: [VisualClassification(identifier: "computer_monitor", score: 0.4)]))
        XCTAssertEqual(decision.confidence, SelfCheckoutEvidence.screenConfidence)
    }

    func testAStaffedCheckoutSignIsNotASelfCheckout() {
        let labels = [VisualClassification(identifier: "computer_monitor", score: 0.9)]
        XCTAssertNil(SelfCheckoutEvidence.decide(lines: [line("Checkout 5")], labels: labels))
    }

    func testUnsureTextIsIgnored() {
        XCTAssertNil(SelfCheckoutEvidence.decide(lines: [line("SELF CHECKOUT", confidence: 0.1)], labels: []))
    }
}

final class CloudSelfCheckoutAnswerTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1440)

    func testNotFoundIsNoSighting() throws {
        let answer = CloudSelfCheckoutAnswer(found: false, box: nil, confidence: 0.9, model: "m")
        XCTAssertNil(try answer.sighting(imageSize: size, orientation: .right))
    }

    func testFoundWithoutABoxIsInvalid() {
        for box in [nil, [0.1, 0.2, 0.3], [0.5, 0.2, 0.3, 0.6], [0.1, 0.2, 1.5, 0.6]] as [[Double]?] {
            let answer = CloudSelfCheckoutAnswer(found: true, box: box, confidence: 0.9, model: "m")
            XCTAssertThrowsError(try answer.sighting(imageSize: size, orientation: .up))
        }
    }

    func testUprightBoxBecomesStoredPixels() throws {
        // Top quarter, left half of an upright image that is stored as is.
        let answer = CloudSelfCheckoutAnswer(found: true, box: [0, 0, 0.25, 0.5], confidence: 0.8, model: "gemini-x")
        let sighting = try XCTUnwrap(try answer.sighting(imageSize: size, orientation: .up))
        XCTAssertEqual(sighting.box, CGRect(x: 0, y: 0, width: 960, height: 360))
        XCTAssertEqual(sighting.source, .cloud(model: "gemini-x"))
    }

    func testRotatedFrameBoxMatchesVisionsConversion() throws {
        // The phone is upright on the cart, so ARKit's landscape image is shown turned (.right).
        let answer = CloudSelfCheckoutAnswer(found: true, box: [0.1, 0.2, 0.4, 0.7], confidence: 0.8, model: "m")
        let sighting = try XCTUnwrap(try answer.sighting(imageSize: size, orientation: .right))
        let back = try VisionRegionOfInterest.normalized(pixelCrop: sighting.box, imageSize: size, orientation: .right)
        // Vision's bottom-left region of the same box: x 0.2…0.7, y from 1 − 0.4 to 1 − 0.1.
        XCTAssertEqual(back.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(back.maxX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(back.minY, 0.6, accuracy: 1e-9)
        XCTAssertEqual(back.maxY, 0.9, accuracy: 1e-9)
    }

    func testEndpointSitsBesideTheProduceEndpoint() throws {
        let produce = try XCTUnwrap(URL(string: "http://mac.local:8787/v1/produce-label"))
        XCTAssertEqual(HTTPCloudSelfCheckoutLocator.endpoint(besides: produce).absoluteString,
                       "http://mac.local:8787/v1/self-checkout")
    }
}

final class SelfCheckoutFinderTests: XCTestCase {
    private struct Offline: Error {}

    /// Answers with `result` and counts its calls.
    private actor Stub: SelfCheckoutLocating {
        let result: Result<SelfCheckoutSighting?, Error>
        private(set) var calls = 0
        init(_ result: Result<SelfCheckoutSighting?, Error>) { self.result = result }
        func locate(_ image: RecognitionImage) async throws -> SelfCheckoutSighting? {
            calls += 1
            return try result.get()
        }
    }

    private let cloudSighting = SelfCheckoutSighting(box: CGRect(x: 1, y: 1, width: 10, height: 10), confidence: 0.9,
                                                     source: .cloud(model: "m"), evidence: "Gemini")
    private let visionSighting = SelfCheckoutSighting(box: CGRect(x: 2, y: 2, width: 10, height: 10), confidence: 0.8,
                                                      source: .appleVision, evidence: "Read “SELF CHECKOUT”")

    private func image(_ timestamp: TimeInterval) -> RecognitionImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return RecognitionImage(timestamp: timestamp, pixelBuffer: buffer!, imageResolution: CGSize(width: 64, height: 48),
                                orientation: .up)
    }

    func testGeminiAnswersFirst() async {
        let cloud = Stub(.success(cloudSighting)), vision = Stub(.success(visionSighting))
        let attempt = await SelfCheckoutFinder(cloud: cloud, onDevice: vision).locate(image(1))
        XCTAssertEqual(attempt.sighting, cloudSighting)
        XCTAssertTrue(attempt.usedCloud)
        let visionCalls = await vision.calls
        XCTAssertEqual(visionCalls, 0)
    }

    func testGeminiSayingNoneIsTheAnswer() async {
        let cloud = Stub(.success(nil)), vision = Stub(.success(visionSighting))
        let attempt = await SelfCheckoutFinder(cloud: cloud, onDevice: vision).locate(image(1))
        XCTAssertNil(attempt.sighting)
        XCTAssertTrue(attempt.usedCloud)
    }

    func testAppleVisionAnswersWhenGeminiFailsThenGeminiRestsForAWhile() async {
        let cloud = Stub(.failure(Offline())), vision = Stub(.success(visionSighting))
        let finder = SelfCheckoutFinder(cloud: cloud, onDevice: vision)
        let first = await finder.locate(image(1))
        XCTAssertEqual(first.sighting, visionSighting)
        XCTAssertFalse(first.usedCloud)
        XCTAssertNotNil(first.cloudProblem)
        _ = await finder.locate(image(1 + SelfCheckoutFinder.cloudRetryAfter - 1))
        var cloudCalls = await cloud.calls
        XCTAssertEqual(cloudCalls, 1)
        _ = await finder.locate(image(1 + SelfCheckoutFinder.cloudRetryAfter))
        cloudCalls = await cloud.calls
        XCTAssertEqual(cloudCalls, 2)
    }

    func testWithoutAProxyAppleVisionAnswers() async {
        let attempt = await SelfCheckoutFinder(cloud: nil, onDevice: Stub(.success(visionSighting))).locate(image(1))
        XCTAssertEqual(attempt.sighting, visionSighting)
        XCTAssertEqual(attempt.cloudProblem, "Gemini proxy not set")
    }
}
