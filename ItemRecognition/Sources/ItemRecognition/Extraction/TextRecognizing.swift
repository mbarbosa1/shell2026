import CoreGraphics
import Foundation

/// One recognized line before normalization
public struct RecognizedTextLine: Sendable, Hashable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// The OCR engine boundary. `VisionTextRecognizer` is the production implementation
public protocol TextRecognizing: Sendable {
    /// Reads text from `image`. When `regionOfInterest` is non-nil, only that
    /// normalized lower-left region is read;
    func recognizeText(
        in image: RecognitionImage,
        regionOfInterest: CGRect?
    ) async throws -> [RecognizedTextLine]
}
