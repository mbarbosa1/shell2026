import CoreGraphics
import Foundation
import Vision

/// Model-free MVP: locates visible text with Vision, unions its boxes, and
/// expands that region before OCR. It does not classify packages or SKUs.
/// Multiple labels in view may share the returned region; upstream crops can
/// isolate a specific product, and catalog matching remains a separate stage.
public struct VisionLabelRegionDetector: LabelRegionDetecting {
    /// Margin on each edge, expressed as a fraction of the detected region's size.
    public let paddingFraction: CGFloat

    public init(paddingFraction: CGFloat = 0.08) {
        self.paddingFraction = paddingFraction.isFinite ? min(max(paddingFraction, 0), 0.5) : 0.08
    }

    public func detectRegion(in image: RecognitionImage) async throws -> CGRect? {
        try TextExtractionScheduler.validate(image, crop: nil)
        let padding = paddingFraction
        return try await Task.detached(priority: .utility) {
            let request = VNDetectTextRectanglesRequest()
            request.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                                orientation: image.orientation, options: [:])
            try handler.perform([request])
            guard let region = Self.paddedRegion(boxes: (request.results ?? []).map(\.boundingBox),
                                                padding: padding) else { return nil }
            return try VisionRegionOfInterest.pixelCrop(normalizedRegion: region,
                                                       imageSize: image.imageResolution,
                                                       orientation: image.orientation)
        }.value
    }

    /// Keep padding inside the image so OCR never receives an invalid ROI.
    static func paddedRegion(boxes: [CGRect], padding: CGFloat) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let valid = boxes.filter {
            $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
                && $0.width > 0 && $0.height > 0
        }.map { $0.intersection(unit) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = valid.first else { return nil }
        let combined = valid.dropFirst().reduce(first) { $0.union($1) }
        return combined.insetBy(dx: -combined.width * padding, dy: -combined.height * padding).intersection(unit)
    }
}
