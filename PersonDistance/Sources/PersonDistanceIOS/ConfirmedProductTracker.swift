#if os(iOS)
import CoreGraphics
import CoreVideo
import Vision

/// Follows the product recognition confirmed from frame to frame with Vision's object tracker
/// (README step 5), so the box that is measured is where the product is now. Recognition stops
/// once the shopper says Yes, so after that nothing else knows.
///
/// Not thread-safe: `ProductRangeSession` calls it from one serial queue.
final class ConfirmedProductTracker: @unchecked Sendable {
    /// Vision's confidence (0–1) below which the product counts as lost rather than guessed at.
    static let minimumConfidence: Float = 0.3

    private let handler = VNSequenceRequestHandler()
    private let request: VNTrackObjectRequest

    /// - Parameters:
    ///   - box: the product in the confirmed frame, in pixels from the image's top left.
    ///   - imageSize: that frame's size.
    init(box: CGRect, imageSize: CGSize) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let start = DepthGeometry.normalizedLowerLeft(box, in: imageSize).intersection(unit)
        request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: start))
        // Pinned like ItemRecognition's `VisionRevisions.tracking`, so an iOS update can't change it.
        request.revision = VNTrackObjectRequestRevision2
        request.trackingLevel = .accurate
    }

    /// Where the product is in `image` (pixels from its top left), or nil when it was lost.
    /// ARKit's image is used as it comes (`.up`): tracking only needs every frame the same way up.
    func track(in image: CVPixelBuffer, imageSize: CGSize) -> CGRect? {
        do {
            try handler.perform([request], on: image, orientation: .up)
        } catch {
            return nil
        }
        guard let found = request.results?.first as? VNDetectedObjectObservation,
              found.confidence >= Self.minimumConfidence else { return nil }
        request.inputObservation = found
        return DepthGeometry.pixels(fromNormalizedLowerLeft: found.boundingBox, in: imageSize)
    }
}
#endif
