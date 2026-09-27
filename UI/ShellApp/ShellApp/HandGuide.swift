import CoreGraphics
import CoreVideo
import ImageIO
import Vision

/// Finds the user's hand in a camera frame and works out which way it should move to reach
/// the product. Uses Apple Vision's built-in hand pose detection, so there's no model to train.
///
/// Directions are in the camera image: "left" means toward the image's left edge. The camera
/// faces the shelf, and so does the user when they reach for it, so the image's left is also
/// the user's left.
///
/// Runs on `PickupGuide`'s background queue (Vision is too slow for the main thread). Only one
/// check runs at a time, hence `@unchecked Sendable`.
final class HandGuide: @unchecked Sendable {
    enum Advice: Equatable {
        case left, right, up, down
        /// The fingertip is on the product.
        case onItem
        /// No hand in the frame.
        case noHand

        var watchHaptic: WatchHaptic {
            switch self {
            case .left: .handLeft
            case .right: .handRight
            case .up: .handUp
            case .down: .handDown
            case .onItem: .handOnItem
            case .noHand: .handGuideOff
            }
        }
    }

    /// How far outside the product's box still counts as "on it", as a fraction of the frame.
    /// A little slack helps, since the fingertip covers the label it's touching.
    var margin: CGFloat = 0.03
    /// Vision's confidence (0–1) needed to trust a joint's position.
    var minimumConfidence: Float = 0.3

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    /// - Parameters:
    ///   - productBox: where the product is, in Vision coordinates (0–1, origin at the bottom
    ///     left) for the same frame orientation.
    ///   - orientation: which way is up in `frame`. `.right` for the back camera with the phone upright.
    func advice(for frame: CVPixelBuffer, orientation: CGImagePropertyOrientation, productBox: CGRect) -> Advice {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation)
        guard (try? handler.perform([request])) != nil,
              let hand = request.results?.first,
              let tip = pointingSpot(of: hand)
        else { return .noHand }

        if productBox.insetBy(dx: -margin, dy: -margin).contains(tip) { return .onItem }

        // Move along whichever axis is farther off first. Vision's y grows upward.
        let dx = productBox.midX - tip.x
        let dy = productBox.midY - tip.y
        if abs(dx) >= abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .up : .down
    }

    /// The index fingertip, since that's what reaches the product first. Falls back to the
    /// middle fingertip, then the wrist, when Vision isn't sure where the finger is.
    private func pointingSpot(of hand: VNHumanHandPoseObservation) -> CGPoint? {
        let joints: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .wrist]
        for joint in joints {
            if let point = try? hand.recognizedPoint(joint), point.confidence >= minimumConfidence {
                return point.location
            }
        }
        return nil
    }
}
