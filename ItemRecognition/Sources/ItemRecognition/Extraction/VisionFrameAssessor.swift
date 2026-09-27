import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Locates foreground objects. One object is followed between fresh segmentations;
/// several are each boxed so the catalog can pick the target's box. A location is
/// not evidence of identity.
public actor VisionFrameAssessor: FrameAssessing {
    private var previous: VNDetectedObjectObservation?
    private var previousTime: TimeInterval?
    private var locatedAt: TimeInterval?
    private var orientation: UInt32?
    private var resolution: CGSize?
    private var sequence = VNSequenceRequestHandler()

    public init() {}

    public func reset() {
        previous = nil; previousTime = nil; locatedAt = nil
        sequence = VNSequenceRequestHandler()
    }

    public func assess(_ image: RecognitionImage) throws -> FrameAssessment {
        try RecognitionFrameScheduler.validate(image, crop: nil)
        let changed = orientation != nil && (orientation != image.orientation.rawValue || resolution != image.imageResolution)
        if changed { reset() }
        orientation = image.orientation.rawValue; resolution = image.imageResolution
        if image.isAdjustingFocus {
            reset()
            return FrameAssessment(objectRegion: nil, quality: .focusing, guidance: .holdSteady, continuityLost: true)
        }
        let old = previous
        let oldTime = previousTime
        var observation: VNDetectedObjectObservation?
        // Refresh segmentation at least once per second; tracking never identifies a new object.
        if let old, let oldTime, image.timestamp > oldTime, image.timestamp - oldTime < 1,
           let locatedAt, image.timestamp - locatedAt < 1 {
            let request = VNTrackObjectRequest(detectedObjectObservation: old)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: image.pixelBuffer, orientation: image.orientation)
            if let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.6 {
                observation = result
            }
        }
        if observation == nil {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer, orientation: image.orientation, options: [:])
            try handler.perform([request])
            guard let mask = request.results?.first, !mask.allInstances.isEmpty else {
                reset()
                return FrameAssessment(objectRegion: nil, quality: .notLocated, continuityLost: true)
            }
            let boxes = Self.droppingSpecks(try mask.allInstances.sorted().compactMap {
                Self.foregroundBounds(try mask.generateMask(forInstances: [$0]))
            })
            guard !boxes.isEmpty else {
                reset()
                return FrameAssessment(objectRegion: nil, quality: .notLocated, continuityLost: true)
            }
            // Several items (milk beside water): box each one and let the catalog pick.
            // Tracking follows one object, so these frames are segmented afresh; the
            // coordinator follows whichever box matched the target.
            if boxes.count > 1 {
                reset()
                return try Self.multipleObjects(boxes, image: image, continuityLost: changed)
            }
            observation = VNDetectedObjectObservation(boundingBox: boxes[0])
            locatedAt = image.timestamp
            sequence = VNSequenceRequestHandler()
        }
        guard let observation else { return FrameAssessment(objectRegion: nil, quality: .notLocated, continuityLost: true) }
        let rect = observation.boundingBox
        let lost = changed || (old != nil && Self.overlap(old!.boundingBox, rect) < 0.15)
        let moving: Bool
        if let old, let oldTime, image.timestamp > oldTime, image.timestamp - oldTime < 1 {
            moving = hypot(rect.midX - old.boundingBox.midX, rect.midY - old.boundingBox.midY)
                / (image.timestamp - oldTime) > 0.8
        } else { moving = false }
        previous = observation; previousTime = image.timestamp
        let quality = Self.quality(for: rect, moving: moving)
        let padded = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = try VisionRegionOfInterest.pixelCrop(normalizedRegion: padded,
            imageSize: image.imageResolution, orientation: image.orientation)
        return FrameAssessment(objectRegion: crop, quality: quality, guidance: Self.guidance(for: quality, rect: rect),
                               continuityLost: lost, objectBoxes: [rect])
    }

    /// An object below this share of the frame is `tooSmall`.
    static let minimumUsableArea: CGFloat = 0.06

    /// Instances smaller than this share of the frame are dropped when others exist.
    static let minimumObjectArea: CGFloat = 0.01

    /// Mask noise beside a real item must not count as a second object. A lone
    /// small object is kept so the user still hears "move forward".
    static func droppingSpecks(_ boxes: [CGRect]) -> [CGRect] {
        guard boxes.count > 1 else { return boxes }
        let kept = boxes.filter { $0.width * $0.height >= minimumObjectArea }
        if !kept.isEmpty { return kept }
        return boxes.max { $0.width * $0.height < $1.width * $1.height }.map { [$0] } ?? []
    }

    /// Several objects: OCR reads the padded union once and the coordinator groups
    /// lines by box. Usable when any one object is readable in size and framing.
    /// Left/right advice waits until the catalog has picked the target's box.
    static func multipleObjects(_ boxes: [CGRect], image: RecognitionImage,
                                continuityLost: Bool) throws -> FrameAssessment {
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        let quality = multipleObjectsQuality(boxes)
        let padded = union.insetBy(dx: -union.width * 0.08, dy: -union.height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = try VisionRegionOfInterest.pixelCrop(normalizedRegion: padded,
            imageSize: image.imageResolution, orientation: image.orientation)
        let guidance = quality == .usable ? nil : guidance(for: quality, rect: union)
        return FrameAssessment(objectRegion: crop, quality: quality, guidance: guidance,
                               continuityLost: continuityLost, objectBoxes: boxes)
    }

    static func multipleObjectsQuality(_ boxes: [CGRect]) -> FrameAssessment.Quality {
        let qualities = boxes.map { quality(for: $0, moving: false) }
        if qualities.contains(.usable) { return .usable }
        let largest = boxes.indices.max { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }
        return largest.map { qualities[$0] } ?? .notLocated
    }

    static func guidance(for quality: FrameAssessment.Quality, rect: CGRect) -> RecognitionGuidance? {
        switch quality {
        case .moving: return .holdSteady
        case .tooSmall: return .moveCloser
        case .clipped: return .moveBack
        default: return VisionLabelRegionDetector.horizontalGuidance(for: rect)
        }
    }

    static func quality(for rect: CGRect, moving: Bool) -> FrameAssessment.Quality {
        if moving { return .moving }
        if rect.width * rect.height < minimumUsableArea { return .tooSmall }
        if rect.width * rect.height > 0.8 || rect.minX < 0.01 || rect.maxX > 0.99 || rect.minY < 0.01 || rect.maxY > 0.99 {
            return .clipped
        }
        return .usable
    }

    /// Intersection over union of two boxes in the same space.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height / max(0.0001, a.width * a.height + b.width * b.height - intersection.width * intersection.height)
    }

    /// Vision mask rows are top-to-bottom; observations use normalized lower-left coordinates.
    static func foregroundBounds(_ buffer: CVPixelBuffer) -> CGRect? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = address.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<width where row[x].isFinite && row[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(width), y: 1 - CGFloat(maxY + 1) / CGFloat(height),
                      width: CGFloat(maxX - minX + 1) / CGFloat(width), height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }
}
