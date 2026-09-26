import CoreGraphics

/// Finds a text-bearing region without recognizing a product's identity.
public protocol LabelRegionDetecting: Sendable {
    /// Returns a top-left pixel crop in the ORIGINAL stored buffer, or nil if
    /// no region was detected. Uses only this image and its orientation.
    func detectRegion(in image: RecognitionImage) async throws -> CGRect?
}
