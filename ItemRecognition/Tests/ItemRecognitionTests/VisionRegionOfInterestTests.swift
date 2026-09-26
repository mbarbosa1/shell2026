import CoreGraphics
import XCTest
@testable import ItemRecognition

final class VisionRegionOfInterestTests: XCTestCase {
    private let imageSize = CGSize(width: 1920, height: 1080)

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
