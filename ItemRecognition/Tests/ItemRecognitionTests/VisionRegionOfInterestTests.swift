import CoreGraphics
import ImageIO
import XCTest
@testable import ItemRecognition

final class VisionRegionOfInterestTests: XCTestCase {
    private let imageSize = CGSize(width: 1920, height: 1080)

    func testKnownAsymmetricCropAcrossAllEightOrientationsAndBack() throws {
        let size = CGSize(width: 100, height: 200)
        let crop = CGRect(x: 10, y: 20, width: 30, height: 40)
        let cases: [(CGImagePropertyOrientation, CGRect)] = [
            (.up, CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.2)),
            (.upMirrored, CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.2)),
            (.down, CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.2)),
            (.downMirrored, CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)),
            (.leftMirrored, CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)),
            (.right, CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.3)),
            (.rightMirrored, CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.3)),
            (.left, CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)),
        ]
        for (orientation, expected) in cases {
            let actual = try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: size, orientation: orientation)
            assertRect(actual, expected)
            // Inverse input is the independently specified expected box, not the forward output.
            let restored = try VisionRegionOfInterest.pixelCrop(normalizedRegion: expected, imageSize: size, orientation: orientation)
            assertRect(restored, crop)
        }
    }

    func testInvalidNormalizedRegionsAndNonFinitePixelsAreRejected() {
        for region in [CGRect.zero, CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
                       CGRect(x: 0.5, y: 0.5, width: 0.6, height: 0.1),
                       CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2)] {
            XCTAssertThrowsError(try VisionRegionOfInterest.pixelCrop(normalizedRegion: region, imageSize: imageSize))
        }
        XCTAssertThrowsError(try VisionRegionOfInterest.normalized(
            pixelCrop: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20), imageSize: imageSize))
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }

    func testTopLeftPixelCropBecomesNormalizedLowerLeftRect() throws {
        // A 480x270 crop whose top-left corner is at (960, 108) in a 1920x1080 image.
        let crop = CGRect(x: 960, y: 108, width: 480, height: 270)

        let roi = try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)

        XCTAssertEqual(roi.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(roi.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(roi.height, 0.25, accuracy: 1e-9)
        // Bottom edge of the crop is at pixel row 378 from the top, so it is
        // 1080 - 378 = 702 px from the bottom, or 0.65 of the height.
        XCTAssertEqual(roi.minY, 0.65, accuracy: 1e-9)
    }

    func testFullImageCropIsTheUnitRect() throws {
        let crop = CGRect(origin: .zero, size: imageSize)

        let roi = try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)

        XCTAssertEqual(roi, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testTopEdgeCropMapsToTopOfNormalizedSpace() throws {
        let crop = CGRect(x: 0, y: 0, width: 1920, height: 270)

        let roi = try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)

        XCTAssertEqual(roi.minY, 0.75, accuracy: 1e-9)
        XCTAssertEqual(roi.maxY, 1.0, accuracy: 1e-9)
    }

    func testCropOutsideImageThrowsInvalidImage() {
        let crop = CGRect(x: 1800, y: 900, width: 400, height: 400)

        XCTAssertThrowsError(
            try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)
        ) { error in
            XCTAssertEqual(
                error as? TextExtractionError,
                .invalidImage(.cropOutsideImage(crop: crop, image: imageSize))
            )
        }
    }

    func testEmptyCropThrowsInvalidImage() {
        let crop = CGRect(x: 10, y: 10, width: 0, height: 50)

        XCTAssertThrowsError(
            try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)
        )
    }

    func testNegativeOriginThrowsInvalidImage() {
        let crop = CGRect(x: -1, y: 10, width: 50, height: 50)

        XCTAssertThrowsError(
            try VisionRegionOfInterest.normalized(pixelCrop: crop, imageSize: imageSize)
        )
    }
}
