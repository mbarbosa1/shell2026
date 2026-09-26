import Foundation

/// Errors raised by the text extraction slice.
///
/// An invalid image is rejected before the activation gate is consulted, so
/// rejecting it changes no gate state and touches no other branch.
public enum TextExtractionError: Error, Equatable {
    case invalidImage(InvalidImageReason)

    public enum InvalidImageReason: Sendable, Equatable {
        /// The buffer or the declared resolution has a zero width or height.
        case zeroDimension
        /// `RecognitionImage.imageResolution` disagrees with the buffer's pixel size.
        case resolutionMismatch(declared: CGSize, buffer: CGSize)
        /// The supplied crop is empty or extends outside the image.
        case cropOutsideImage(crop: CGRect, image: CGSize)
    }
}
