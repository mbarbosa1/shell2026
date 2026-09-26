import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import ItemRecognition

/// Real Vision smoke checks. These verify the installed model and image contract,
/// not onion accuracy. Real produce/device evaluation remains a separate task.
final class VisionImageClassifierTests: XCTestCase {
    func testInstalledVisionVocabularyContainsOnion() async throws {
        let info = try await VisionImageClassifier().modelInfo()
        XCTAssertEqual(info.id, VisionImageClassifier.modelID)
        XCTAssertTrue(info.supportedClassIDs.contains("onion"))
        XCTAssertTrue(info.supportedClassIDs.contains("potato"))
        XCTAssertFalse(info.version.isEmpty)
    }

    func testRealInferenceAcceptsOrientedPixelBufferAndExplicitCrop() async throws {
        let classifier = VisionImageClassifier()
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                          attributes, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            // A neutral, initialized image: no fabricated onion fixture/label.
            memset(address, 128, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let crop = CGRect(x: 40, y: 30, width: 160, height: 120)
        let image = RecognitionImage(timestamp: 42, pixelBuffer: pixels,
            imageResolution: CGSize(width: 320, height: 240), orientation: .rightMirrored)
        let observation = try await classifier.classify(in: image, crop: crop)
        XCTAssertEqual(observation.timestamp, 42)
        XCTAssertEqual(observation.inputRegion, crop)
        XCTAssertEqual(observation.modelID, VisionImageClassifier.modelID)
        XCTAssertFalse(observation.classifications.isEmpty)
        XCTAssertTrue(observation.classifications.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) })
    }
}
