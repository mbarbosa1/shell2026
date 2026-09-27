import CoreGraphics
import CoreVideo
import ImageIO
import Vision

/// Follows one product from frame to frame with Vision's object tracker, once item recognition has
/// found it. It takes a few milliseconds a frame, far faster than recognizing the product again, so
/// the arm can keep it centered while the cart moves.
///
/// Runs on `PickupGuide`'s background queue, one frame at a time, hence `@unchecked Sendable`.
final class ProductTracker: @unchecked Sendable {
    /// Below this, Vision is guessing: the product left the frame or something covers it.
    private static let minimumConfidence: Float = 0.3

    private let handler = VNSequenceRequestHandler()
    /// Kept for the whole track: the tracker's memory of the product lives in the request.
    private let request: VNTrackObjectRequest

    /// `box` in Vision coordinates (0–1, origin at the bottom left), in the image oriented like
    /// the frames `follow` gets.
    init(box: CGRect) {
        request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
    }

    /// Where the product is in `frame` now, in the same coordinates, or nil when it's lost.
    func follow(in frame: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGRect? {
        do {
            try handler.perform([request], on: frame, orientation: orientation)
        } catch {
            return nil
        }
        guard let result = request.results?.first as? VNDetectedObjectObservation,
              result.confidence >= Self.minimumConfidence else { return nil }
        request.inputObservation = result
        return result.boundingBox
    }
}
