import CoreGraphics
import XCTest
@testable import ItemRecognition

final class VisionLabelRegionDetectorTests: XCTestCase {
    func testPaddingIncludesAllDetectedTextAndClipsToImageEdges() throws {
        let region = try XCTUnwrap(VisionLabelRegionDetector.paddedRegion(boxes: [
            CGRect(x: 0.02, y: 0.1, width: 0.3, height: 0.2),
            CGRect(x: 0.2, y: 0.7, width: 0.7, height: 0.28),
        ], padding: 0.1))
        XCTAssertEqual(region.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(region.minY, 0.012, accuracy: 1e-9)
        XCTAssertEqual(region.maxX, 0.988, accuracy: 1e-9)
        XCTAssertEqual(region.maxY, 1, accuracy: 1e-9)
    }

    func testEmptyOrInvalidBoxesProduceNoRegion() {
        XCTAssertNil(VisionLabelRegionDetector.paddedRegion(boxes: [], padding: 0.08))
        XCTAssertNil(VisionLabelRegionDetector.paddedRegion(boxes: [
            .zero, CGRect(x: 2, y: 2, width: 1, height: 1),
            CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2),
        ], padding: 0.08))
    }

    func testPaddingConfigurationRemainsFiniteAndBounded() {
        XCTAssertEqual(VisionLabelRegionDetector(paddingFraction: -1).paddingFraction, 0)
        XCTAssertEqual(VisionLabelRegionDetector(paddingFraction: 2).paddingFraction, 0.5)
        XCTAssertEqual(VisionLabelRegionDetector(paddingFraction: .nan).paddingFraction, 0.08)
        XCTAssertEqual(VisionLabelRegionDetector(minimumPackageConfidence: 3).minimumPackageConfidence, 1)
        XCTAssertEqual(VisionLabelRegionDetector(minimumPackageConfidence: .nan).minimumPackageConfidence, 0.5)
        XCTAssertEqual(VisionLabelRegionDetector(minimumTextHeight: -5).minimumTextHeight, 0)
        XCTAssertEqual(VisionLabelRegionDetector(minimumTextHeight: .infinity).minimumTextHeight, 32)
        XCTAssertEqual(VisionLabelRegionDetector().minimumPackageConfidence, 0.5)
        XCTAssertEqual(VisionLabelRegionDetector().minimumTextHeight, 32)
    }

    // MARK: - Package crop

    private typealias Candidate = VisionLabelRegionDetector.PackageCandidate
    private let cereal = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)

    func testLargestConfidentRectangleIsThePackage() throws {
        let region = VisionLabelRegionDetector.packageRegion([
            Candidate(boundingBox: CGRect(x: 0.05, y: 0.1, width: 0.2, height: 0.3), confidence: 0.9), // small
            Candidate(boundingBox: cereal, confidence: 0.6),
            Candidate(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.49), // large but weak
        ], minimumConfidence: 0.5)
        let picked = try XCTUnwrap(region)
        XCTAssertEqual(picked.minX, cereal.minX, accuracy: 1e-9)
        XCTAssertEqual(picked.minY, cereal.minY, accuracy: 1e-9)
        XCTAssertEqual(picked.maxX, cereal.maxX, accuracy: 1e-9)
        XCTAssertEqual(picked.maxY, cereal.maxY, accuracy: 1e-9)
    }

    func testNoRectangleAtThresholdMeansNoPackage() {
        XCTAssertNil(VisionLabelRegionDetector.packageRegion([
            Candidate(boundingBox: cereal, confidence: 0.49),
            Candidate(boundingBox: CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5), confidence: 0.9),
            Candidate(boundingBox: CGRect(x: 2, y: 2, width: 1, height: 1), confidence: 0.9),
        ], minimumConfidence: 0.5))
        XCTAssertNil(VisionLabelRegionDetector.packageRegion([], minimumConfidence: 0.5))
    }

    func testTextInsideThePackageIsUnionedAndClippedToIt() throws {
        let brand = CGRect(x: 0.35, y: 0.6, width: 0.3, height: 0.29) // reaches 0.89; padding would pass 0.9
        let size = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.05)
        let neighbor = CGRect(x: 0.75, y: 0.5, width: 0.2, height: 0.1) // another box on the shelf
        let region = try XCTUnwrap(VisionLabelRegionDetector.region(
            textBoxes: [brand, size, neighbor], packages: [Candidate(boundingBox: cereal, confidence: 0.7)],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920))
        XCTAssertTrue(cereal.contains(region), "padding never leaves the package")
        XCTAssertTrue(region.contains(brand) && region.contains(size))
        XCTAssertFalse(region.intersects(neighbor), "text on the neighboring package is excluded")
        XCTAssertEqual(region.minX, 0.35 - 0.3 * 0.08, accuracy: 1e-9)
        XCTAssertEqual(region.maxY, cereal.maxY, accuracy: 1e-9, "clipped to the package top")
    }

    func testTextTooSmallInsideThePackageSkipsOCR() {
        let tiny = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.01) // 19 px at 1920
        XCTAssertNil(VisionLabelRegionDetector.region(
            textBoxes: [tiny], packages: [Candidate(boundingBox: cereal, confidence: 0.7)],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920))
        let readable = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.02) // 38 px at 1920
        XCTAssertNotNil(VisionLabelRegionDetector.region(
            textBoxes: [readable], packages: [Candidate(boundingBox: cereal, confidence: 0.7)],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920))
    }

    func testPackageWithoutTextSkipsOCR() {
        let outside = CGRect(x: 0.8, y: 0.5, width: 0.1, height: 0.1)
        XCTAssertNil(VisionLabelRegionDetector.region(
            textBoxes: [outside], packages: [Candidate(boundingBox: cereal, confidence: 0.7)],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920))
    }

    func testNoPackageFallsBackToFullFrameTextUnion() throws {
        let page = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.005), CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.005)]
        let region = try XCTUnwrap(VisionLabelRegionDetector.region(
            textBoxes: page, packages: [Candidate(boundingBox: cereal, confidence: 0.3)],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920))
        XCTAssertEqual(region, try XCTUnwrap(VisionLabelRegionDetector.paddedRegion(boxes: page, padding: 0.08)),
                       "a printed page in camera-only mode still reads; no height gate without a package")
    }

    // MARK: - User guidance

    private typealias Decision = VisionLabelRegionDetector.Decision

    private func decide(text: [CGRect], package: CGRect?, confidence: Float = 0.7) -> Decision {
        VisionLabelRegionDetector.decide(
            textBoxes: text, packages: package.map { [Candidate(boundingBox: $0, confidence: confidence)] } ?? [],
            padding: 0.08, minimumPackageConfidence: 0.5, minimumTextHeight: 32, orientedImageHeight: 1920)
    }

    func testFarPackageWithTinyTextSaysMoveCloser() {
        let far = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3) // 6% of the frame
        let tiny = CGRect(x: 0.45, y: 0.5, width: 0.1, height: 0.005)
        let decision = decide(text: [tiny], package: far)
        XCTAssertNil(decision.region, "no OCR on unreadable text")
        XCTAssertEqual(decision.guidance, .moveCloser)
        XCTAssertEqual(decision.guidance?.message, "Move closer to the item")
    }

    func testNearPackageWithTinyTextSaysKeepWalking() {
        let near = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8) // 48% of the frame
        let tiny = CGRect(x: 0.45, y: 0.5, width: 0.1, height: 0.005)
        let decision = decide(text: [tiny], package: near)
        XCTAssertNil(decision.region)
        XCTAssertEqual(decision.guidance, .keepWalking)
        XCTAssertEqual(decision.guidance?.message, "Keep walking toward the item")
    }

    func testPackageOnTheLeftReadsAndSaysMoveLeft() {
        let leftPackage = CGRect(x: 0.02, y: 0.1, width: 0.3, height: 0.8) // centre x 0.17
        let readable = CGRect(x: 0.05, y: 0.5, width: 0.2, height: 0.03)
        let decision = decide(text: [readable], package: leftPackage)
        XCTAssertNotNil(decision.region, "an off-centre item is still read this frame")
        XCTAssertEqual(decision.guidance, .moveLeft)
        XCTAssertEqual(decision.guidance?.message, "Move more to the left")
    }

    func testPackageOnTheRightReadsAndSaysMoveRight() {
        let rightPackage = CGRect(x: 0.68, y: 0.1, width: 0.3, height: 0.8) // centre x 0.83
        let readable = CGRect(x: 0.7, y: 0.5, width: 0.2, height: 0.03)
        let decision = decide(text: [readable], package: rightPackage)
        XCTAssertNotNil(decision.region)
        XCTAssertEqual(decision.guidance, .moveRight)
        XCTAssertEqual(decision.guidance?.message, "Move more to the right")
    }

    func testCenteredLegiblePackageNeedsNoGuidance() {
        let readable = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.03)
        let decision = decide(text: [readable], package: cereal) // centre x 0.5
        XCTAssertNotNil(decision.region)
        XCTAssertNil(decision.guidance)
    }

    func testBandEdgesCountAsCentered() {
        XCTAssertNil(VisionLabelRegionDetector.horizontalGuidance(for: CGRect(x: 0.25, y: 0, width: 0.2, height: 0.5))) // 0.35
        XCTAssertNil(VisionLabelRegionDetector.horizontalGuidance(for: CGRect(x: 0.55, y: 0, width: 0.2, height: 0.5))) // 0.65
        XCTAssertEqual(VisionLabelRegionDetector.horizontalGuidance(for: CGRect(x: 0.2, y: 0, width: 0.2, height: 0.5)), .moveLeft)
        XCTAssertEqual(VisionLabelRegionDetector.horizontalGuidance(for: CGRect(x: 0.6, y: 0, width: 0.2, height: 0.5)), .moveRight)
        XCTAssertNil(VisionLabelRegionDetector.horizontalGuidance(for: CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.5)))
    }

    func testNoPackageUsesTextPositionForLeftRight() {
        let leftText = [CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.05)]
        let decision = decide(text: leftText, package: nil)
        XCTAssertNotNil(decision.region, "full-frame fallback still reads")
        XCTAssertEqual(decision.guidance, .moveLeft)
        let centred = decide(text: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05)], package: nil)
        XCTAssertNil(centred.guidance)
    }

    func testNothingInFrameSaysMoveCloser() {
        let decision = decide(text: [], package: nil)
        XCTAssertNil(decision.region)
        XCTAssertEqual(decision.guidance, .moveCloser)
        let weakPackageOnly = decide(text: [], package: cereal, confidence: 0.3)
        XCTAssertEqual(weakPackageOnly.guidance, .moveCloser, "a rectangle under 0.5 is not a package")
    }

    func testLegibilityUsesOrientedImageHeight() {
        let stored = CGSize(width: 1920, height: 1080) // landscape buffer
        XCTAssertEqual(VisionLabelRegionDetector.orientedSize(stored, orientation: .right), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(VisionLabelRegionDetector.orientedSize(stored, orientation: .up), stored)
        let line = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.02)
        XCTAssertTrue(VisionLabelRegionDetector.isLegible(textBoxes: [line], orientedImageHeight: 1920, minimumTextHeight: 32))
        XCTAssertFalse(VisionLabelRegionDetector.isLegible(textBoxes: [line], orientedImageHeight: 1080, minimumTextHeight: 32))
        XCTAssertFalse(VisionLabelRegionDetector.isLegible(textBoxes: [], orientedImageHeight: 1920, minimumTextHeight: 32))
        XCTAssertFalse(VisionLabelRegionDetector.isLegible(textBoxes: [line], orientedImageHeight: 0, minimumTextHeight: 32))
    }
}
