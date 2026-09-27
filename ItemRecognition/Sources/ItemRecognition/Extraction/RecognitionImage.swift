import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// One camera frame handed to this package by the upstream camera owner.
///
/// Ownership rule for `@unchecked Sendable`: the caller keeps `pixelBuffer`
///
/// `imageResolution` is the pixel size of the buffer as stored
public struct RecognitionImage: @unchecked Sendable {
    public let timestamp: TimeInterval
    public let pixelBuffer: CVPixelBuffer
    public let imageResolution: CGSize
    public let orientation: CGImagePropertyOrientation
    public let isAdjustingFocus: Bool

    public init(
        timestamp: TimeInterval,
        pixelBuffer: CVPixelBuffer,
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation,
        isAdjustingFocus: Bool = false
    ) {
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
        self.imageResolution = imageResolution
        self.orientation = orientation
        self.isAdjustingFocus = isAdjustingFocus
    }
}
