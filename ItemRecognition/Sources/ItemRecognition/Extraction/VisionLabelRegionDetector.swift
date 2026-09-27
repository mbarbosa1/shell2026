import CoreGraphics
import Foundation
import Vision

/// Model-free MVP: crops to the package before OCR. Vision's rectangle detector
/// proposes the package; text inside that rectangle is unioned and padded, and
/// OCR later reads that region of the ORIGINAL buffer. Nothing is upscaled: a
/// crop whose tallest text line is under `minimumTextHeight` returns no crop
/// but keeps a plain-language reason ("move closer" / "keep walking") so the
/// scheduler skips OCR and the app can tell the user what to do. Off-centre
/// packages add a left/right hint alongside a usable crop. When no rectangle
/// reaches `minimumPackageConfidence`, every visible text box is unioned as
/// before so a printed page still reads. This does not classify packages or
/// SKUs, and the package confidence only accepts the crop; catalog matching
/// stays separate.
public struct VisionLabelRegionDetector: LabelRegionDetecting {
    /// Margin on each edge, expressed as a fraction of the detected region's size.
    public let paddingFraction: CGFloat
    /// `VNDetectRectanglesRequest` confidence needed to treat a rectangle as the package.
    public let minimumPackageConfidence: Float
    /// Tallest text line inside the package, in oriented image pixels, needed to run OCR.
    public let minimumTextHeight: CGFloat

    public init(paddingFraction: CGFloat = 0.08, minimumPackageConfidence: Float = 0.5,
                minimumTextHeight: CGFloat = 32) {
        self.paddingFraction = paddingFraction.isFinite ? min(max(paddingFraction, 0), 0.5) : 0.08
        self.minimumPackageConfidence = minimumPackageConfidence.isFinite
            ? min(max(minimumPackageConfidence, 0), 1) : 0.5
        self.minimumTextHeight = minimumTextHeight.isFinite ? max(0, minimumTextHeight) : 32
    }

    public func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection {
        try await detectRegion(in: image, within: nil)
    }

    public func detectRegion(in image: RecognitionImage, within objectRegion: CGRect?) async throws -> LabelRegionDetection {
        try TextExtractionScheduler.validate(image, crop: nil)
        let padding = paddingFraction
        let packageConfidence = minimumPackageConfidence
        let textHeight = minimumTextHeight
        return try await Task.detached(priority: .utility) {
            let rectangles = VNDetectRectanglesRequest()
            rectangles.maximumObservations = 3
            rectangles.minimumConfidence = packageConfidence
            rectangles.minimumAspectRatio = 0.3
            rectangles.maximumAspectRatio = 1
            let text = VNDetectTextRectanglesRequest()
            text.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                                orientation: image.orientation, options: [:])
            try handler.perform([rectangles, text])
            let boxes = (text.results ?? []).map(\.boundingBox)
            let candidates: [PackageCandidate]
            if let objectRegion {
                candidates = [PackageCandidate(boundingBox: try VisionRegionOfInterest.normalized(pixelCrop: objectRegion,
                    imageSize: image.imageResolution, orientation: image.orientation), confidence: 1)]
            } else {
                candidates = (rectangles.results ?? []).map { PackageCandidate(boundingBox: $0.boundingBox, confidence: $0.confidence) }
            }
            let orientedHeight = Self.orientedSize(image.imageResolution, orientation: image.orientation).height
            let decision = Self.decide(textBoxes: boxes, packages: candidates, padding: padding,
                                       minimumPackageConfidence: packageConfidence,
                                       minimumTextHeight: textHeight, orientedImageHeight: orientedHeight)
            guard let region = decision.region else {
                return LabelRegionDetection(crop: nil, guidance: decision.guidance, readiness: decision.readiness)
            }
            let crop = try VisionRegionOfInterest.pixelCrop(normalizedRegion: region,
                                                            imageSize: image.imageResolution,
                                                            orientation: image.orientation)
            return LabelRegionDetection(crop: crop, guidance: decision.guidance, readiness: decision.readiness)
        }.value
    }

    /// One rectangle proposal in Vision's normalized lower-left oriented space.
    struct PackageCandidate: Equatable {
        let boundingBox: CGRect
        let confidence: Float
    }

    /// Normalized OCR region (nil = skip OCR) plus the advice to show the user.
    struct Decision: Equatable {
        let region: CGRect?
        let guidance: RecognitionGuidance?
        var readiness: LabelRegionDetection.Readiness = .readable
    }

    /// Items whose horizontal centre falls outside this band earn a left/right hint.
    static let centeredBand: ClosedRange<CGFloat> = 0.35...0.65
    /// A package covering less than this share of the frame is "far": move closer.
    /// A larger package with unreadable text is "almost there": keep walking.
    static let smallPackageArea: CGFloat = 0.25

    /// Full decision for one frame, in normalized oriented coordinates.
    /// Package found: text inside it, padded and clipped to the package. Text too
    /// small: no region, but the reason survives as guidance. Off-centre package
    /// or text: a usable region plus a left/right hint. No package and no text:
    /// no region, move closer.
    static func decide(textBoxes: [CGRect], packages: [PackageCandidate], padding: CGFloat,
                       minimumPackageConfidence: Float, minimumTextHeight: CGFloat,
                       orientedImageHeight: CGFloat) -> Decision {
        guard let package = packageRegion(packages, minimumConfidence: minimumPackageConfidence) else {
            guard let union = paddedRegion(boxes: textBoxes, padding: padding) else {
                return Decision(region: nil, guidance: .moveCloser, readiness: .unsuitable)
            }
            return Decision(region: union, guidance: horizontalGuidance(for: union))
        }
        let inside = textBoxes.map { $0.intersection(package) }.filter { !$0.isNull && !$0.isEmpty }
        guard !inside.isEmpty else {
            return Decision(region: nil, guidance: horizontalGuidance(for: package), readiness: .noText)
        }
        guard isLegible(textBoxes: inside, orientedImageHeight: orientedImageHeight,
                        minimumTextHeight: minimumTextHeight) else {
            let far = package.width * package.height < smallPackageArea
            // A near package with tiny text is fine print: stepping back would only shrink it.
            return Decision(region: nil, guidance: far ? .moveCloser : .keepWalking, readiness: .textTooSmall)
        }
        return Decision(region: paddedRegion(boxes: inside, padding: padding, within: package),
                        guidance: horizontalGuidance(for: package))
    }

    /// Backwards-compatible region-only view of `decide`.
    static func region(textBoxes: [CGRect], packages: [PackageCandidate], padding: CGFloat,
                       minimumPackageConfidence: Float, minimumTextHeight: CGFloat,
                       orientedImageHeight: CGFloat) -> CGRect? {
        decide(textBoxes: textBoxes, packages: packages, padding: padding,
               minimumPackageConfidence: minimumPackageConfidence, minimumTextHeight: minimumTextHeight,
               orientedImageHeight: orientedImageHeight).region
    }

    /// The direction the user should step so the item sits nearer the centre of
    /// the phone. An item on the left of the frame means "move more to the left".
    static func horizontalGuidance(for rect: CGRect) -> RecognitionGuidance? {
        guard isFinite(rect), rect.width > 0 else { return nil }
        let centerX = rect.midX
        if centerX < centeredBand.lowerBound { return .moveLeft }
        if centerX > centeredBand.upperBound { return .moveRight }
        return nil
    }

    /// Largest rectangle at or above `minimumConfidence`, clipped to the image.
    /// The score only accepts the crop; it is not evidence of any product.
    static func packageRegion(_ candidates: [PackageCandidate], minimumConfidence: Float) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return candidates
            .filter { $0.confidence.isFinite && $0.confidence >= minimumConfidence && isFinite($0.boundingBox) }
            .map { $0.boundingBox.intersection(unit) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// True when the tallest text line covers at least `minimumTextHeight`
    /// oriented pixels. Below that, OCR would only read interpolated pixels.
    static func isLegible(textBoxes: [CGRect], orientedImageHeight: CGFloat, minimumTextHeight: CGFloat) -> Bool {
        guard orientedImageHeight.isFinite, orientedImageHeight > 0 else { return false }
        let tallest = textBoxes.filter(isFinite).map(\.height).max() ?? 0
        return tallest * orientedImageHeight >= minimumTextHeight
    }

    /// Keep padding inside the image (or the package) so OCR never receives an invalid ROI.
    static func paddedRegion(boxes: [CGRect], padding: CGFloat, within bounds: CGRect? = nil) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let limit = bounds.map { $0.intersection(unit) } ?? unit
        guard !limit.isNull, !limit.isEmpty else { return nil }
        let valid = boxes.filter(isFinite).filter { $0.width > 0 && $0.height > 0 }
            .map { $0.intersection(limit) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = valid.first else { return nil }
        let combined = valid.dropFirst().reduce(first) { $0.union($1) }
        return combined.insetBy(dx: -combined.width * padding, dy: -combined.height * padding).intersection(limit)
    }

    /// Pixel size of the image after applying its orientation.
    static func orientedSize(_ stored: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: stored.height, height: stored.width)
        default:
            return stored
        }
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
