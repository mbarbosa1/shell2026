import CoreGraphics

/// Plain-language direction for the user, derived from where the package or
/// its text sits in the frame. Never coordinates: the app shows `message` as is.
public enum RecognitionGuidance: String, Sendable, Equatable, Codable {
    case moveCloser
    case keepWalking
    case moveLeft
    case moveRight
    case moveBack
    case holdSteady
    case showLabel

    public var message: String {
        switch self {
        case .moveCloser: return "Move closer to the item"
        case .keepWalking: return "Keep walking toward the item"
        case .moveLeft: return "Move more to the left"
        case .moveRight: return "Move more to the right"
        case .moveBack: return "Move back"
        case .holdSteady: return "Hold the phone steady"
        case .showLabel: return "Turn the label toward the camera"
        }
    }
}

/// Which recognizer produced the current update. Shown on every processed
/// frame so the user knows when a heavier model (Gemini) replaced OCR or
/// on-device Apple Vision.
public enum RecognitionModeNotice: String, Sendable, Equatable, Codable {
    case ocrOnly
    case appleVision
    case cloudAssist

    public var message: String {
        switch self {
        case .ocrOnly: return "Reading words"
        case .appleVision: return "Recognizing appearance"
        case .cloudAssist: return "Result from cloud assist (Gemini)"
        }
    }
}

/// Result of one detection pass. `crop` is a top-left pixel rectangle in the
/// ORIGINAL stored buffer; nil means OCR must not run on this frame. `guidance`
/// survives even when `crop` is nil so the reason is never dropped.
public struct LabelRegionDetection: Sendable, Equatable {
    public enum Readiness: String, Sendable, Equatable, Codable {
        case readable, noText, textTooSmall, unsuitable
    }
    public let crop: CGRect?
    public let guidance: RecognitionGuidance?
    public let readiness: Readiness
    public init(crop: CGRect?, guidance: RecognitionGuidance? = nil, readiness: Readiness? = nil) {
        self.crop = crop
        self.guidance = guidance
        self.readiness = readiness ?? (crop == nil ? .unsuitable : .readable)
    }
    /// A frame with nothing to read and no advice to give.
    public static let none = LabelRegionDetection(crop: nil, guidance: nil)
}

/// Finds a text-bearing region without recognizing a product's identity.
public protocol LabelRegionDetecting: Sendable {
    /// Uses only this image and its orientation.
    func detectRegion(in image: RecognitionImage) async throws -> LabelRegionDetection
    func detectRegion(in image: RecognitionImage, within objectRegion: CGRect?) async throws -> LabelRegionDetection
}

public extension LabelRegionDetecting {
    func detectRegion(in image: RecognitionImage, within objectRegion: CGRect?) async throws -> LabelRegionDetection {
        try await detectRegion(in: image)
    }
}
