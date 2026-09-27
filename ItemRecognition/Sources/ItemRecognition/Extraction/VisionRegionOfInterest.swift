import CoreGraphics
import Foundation
import ImageIO

/// Converts a caller-supplied pixel crop into the normalized rectangle that Vision's `regionOfInterest` expects
///
/// Input: a rectangle in stored-buffer pixel coordinates with a top-left origin
/// 
/// Output: normalized lower-left coordinates in the image AFTER applying orientation.

public enum VisionRegionOfInterest {
    public static func normalized(
        pixelCrop crop: CGRect, imageSize: CGSize, orientation: CGImagePropertyOrientation = .up
    ) throws -> CGRect {
        try validate(pixelCrop: crop, imageSize: imageSize)
        let stored = CGRect(x: crop.minX / imageSize.width, y: crop.minY / imageSize.height,
                            width: crop.width / imageSize.width, height: crop.height / imageSize.height)
        let oriented = map(stored, orientation: orientation)
        return CGRect(x: oriented.minX, y: 1 - oriented.maxY, width: oriented.width, height: oriented.height)
    }

    /// Converts Vision's oriented, lower-left normalized box back into a crop
    /// of the original stored buffer, with a top-left pixel origin.
    public static func pixelCrop(
        normalizedRegion region: CGRect, imageSize: CGSize, orientation: CGImagePropertyOrientation = .up
    ) throws -> CGRect {
        guard isFinite(region), region.width > 0, region.height > 0,
              region.minX >= 0, region.minY >= 0, region.maxX <= 1, region.maxY <= 1 else {
            throw TextExtractionError.invalidImage(.invalidRegionOfInterest(region))
        }
        let oriented = CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height)
        let inverse: CGImagePropertyOrientation
        switch orientation {
        case .right: inverse = .left
        case .left: inverse = .right
        default: inverse = orientation
        }
        let stored = map(oriented, orientation: inverse)
        // Clip only floating-point roundoff at image edges; invalid input was rejected above.
        let crop = CGRect(x: stored.minX * imageSize.width, y: stored.minY * imageSize.height,
                          width: stored.width * imageSize.width, height: stored.height * imageSize.height)
            .intersection(CGRect(origin: .zero, size: imageSize))
        try validate(pixelCrop: crop, imageSize: imageSize)
        return crop
    }

    /// Throws `TextExtractionError.invalidImage(.cropOutsideImage)` when the
    /// crop is empty or any edge lies outside the image.
    public static func validate(pixelCrop crop: CGRect, imageSize: CGSize) throws {
        let inside = imageSize.width.isFinite && imageSize.height.isFinite
            && imageSize.width > 0 && imageSize.height > 0
            && isFinite(crop) && crop.width > 0
            && crop.height > 0
            && crop.minX >= 0
            && crop.minY >= 0
            && crop.maxX <= imageSize.width
            && crop.maxY <= imageSize.height
        guard inside else {
            throw TextExtractionError.invalidImage(.cropOutsideImage(crop: crop, image: imageSize))
        }
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    /// Apply EXIF orientation in normalized TOP-left space, independent of aspect ratio.
    private static func map(_ rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        let mapped = corners.map { point -> CGPoint in
            let x = point.x, y = point.y
            switch orientation {
            case .up: return CGPoint(x: x, y: y)
            case .upMirrored: return CGPoint(x: 1 - x, y: y)
            case .down: return CGPoint(x: 1 - x, y: 1 - y)
            case .downMirrored: return CGPoint(x: x, y: 1 - y)
            case .leftMirrored: return CGPoint(x: y, y: x)
            case .right: return CGPoint(x: 1 - y, y: x)
            case .rightMirrored: return CGPoint(x: 1 - y, y: 1 - x)
            case .left: return CGPoint(x: y, y: 1 - x)
            @unknown default: return point
            }
        }
        let xs = mapped.map(\.x), ys = mapped.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
