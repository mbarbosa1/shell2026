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
    }
}
