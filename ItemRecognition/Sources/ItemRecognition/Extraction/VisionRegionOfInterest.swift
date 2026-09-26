import CoreGraphics
import Foundation

/// Converts a caller-supplied pixel crop into the normalized rectangle that Vision's `regionOfInterest` expects
///
/// Input: a rectangle in stored-buffer pixel coordinates with a top-left origin
/// 
///  Output: a rectangle normalized to 0...1 on both axes with a lower-left origin

public enum VisionRegionOfInterest {
    public static func normalized(pixelCrop crop: CGRect, imageSize: CGSize) throws -> CGRect {
        try validate(pixelCrop: crop, imageSize: imageSize)

        let x = crop.minX / imageSize.width
        let width = crop.width / imageSize.width
        let height = crop.height / imageSize.height
        // Top-left origin to lower-left origin: the distance from the bottom
        // of the image to the bottom of the crop.
        let y = 1.0 - (crop.maxY / imageSize.height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Throws `TextExtractionError.invalidImage(.cropOutsideImage)` when the
    /// crop is empty or any edge lies outside the image.
    public static func validate(pixelCrop crop: CGRect, imageSize: CGSize) throws {
        let inside = crop.width > 0
            && crop.height > 0
            && crop.minX >= 0
            && crop.minY >= 0
            && crop.maxX <= imageSize.width
            && crop.maxY <= imageSize.height
        guard inside else {
            throw TextExtractionError.invalidImage(.cropOutsideImage(crop: crop, image: imageSize))
        }
    }
}
