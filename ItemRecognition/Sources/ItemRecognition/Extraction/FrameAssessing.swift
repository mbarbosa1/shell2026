import CoreGraphics
import Foundation

public struct FrameAssessment: Sendable, Equatable {
    public enum Quality: String, Sendable, Codable {
        case usable, notLocated, multipleObjects, moving, focusing, tooSmall, clipped
    }
    /// Original-buffer pixels. This is an object region, never a text crop.
    /// With several objects in view it covers all of them, so one OCR pass reads each.
    public let objectRegion: CGRect?
    /// One box per foreground object, normalized lower-left in the oriented image:
    /// the same space as OCR line boxes. Several boxes let the catalog decide which
    /// object's text is the target. Empty when the assessor reports none.
    public let objectBoxes: [CGRect]
    public let quality: Quality
    public let guidance: RecognitionGuidance?
    public let continuityLost: Bool
    public var isSuitable: Bool { quality == .usable && objectRegion != nil }
    public var message: String {
        switch quality {
        case .usable: return "Item located"
        case .notLocated: return "Point the camera at one item"
        case .multipleObjects: return "Frame one item at a time"
        case .moving, .focusing: return "Hold the phone steady"
        case .tooSmall: return "Move forward"
        case .clipped: return "Move back"
        }
    }
    public init(objectRegion: CGRect?, quality: Quality, guidance: RecognitionGuidance? = nil,
                continuityLost: Bool = false, objectBoxes: [CGRect] = []) {
        self.objectRegion = objectRegion; self.objectBoxes = objectBoxes; self.quality = quality
        self.guidance = guidance; self.continuityLost = continuityLost
    }
}

public protocol FrameAssessing: Sendable {
    func assess(_ image: RecognitionImage) async throws -> FrameAssessment
    func reset() async
}

public extension FrameAssessing { func reset() async {} }
