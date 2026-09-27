import CoreGraphics
import Foundation

/// Database-owned eligibility; labels must match a specific model's vocabulary.
/// A broad class such as "onion" does not establish a yellow/organic/packaged SKU.
public struct VisualCatalogMetadata: Sendable, Hashable, Codable {
    public let modelID: String
    public let classIDs: Set<String>
    public let allowsConfirmation: Bool
    public init(modelID: String, classIDs: Set<String>, allowsConfirmation: Bool = false) {
        self.modelID = modelID
        self.classIDs = classIDs
        self.allowsConfirmation = allowsConfirmation
    }
}

public struct VisualModelInfo: Sendable, Equatable {
    public let id: String
    public let version: String
    public let supportedClassIDs: Set<String>
    public init(id: String, version: String, supportedClassIDs: Set<String>) {
        self.id = id; self.version = version; self.supportedClassIDs = supportedClassIDs
    }
}

public struct VisualClassification: Sendable, Equatable {
    public let identifier: String
    /// Model score, not a calibrated probability of an exact catalog match.
    public let score: Float
    public init(identifier: String, score: Float) {
        self.identifier = identifier; self.score = score
    }
}

public struct VisualObservation: Sendable, Equatable {
    public enum Kind: String, Sendable { case modelScores, cloudSuggestion }
    public let timestamp: TimeInterval
    public let modelID: String
    public let modelVersion: String
    /// Original-buffer pixel region supplied to inference, NOT an object box.
    public let inputRegion: CGRect
    public let classifications: [VisualClassification]
    public let kind: Kind
    public let diagnostic: String?
    /// Raw model label behind the `unknown` score (e.g. "table"). Diagnostics only.
    public let backgroundLabel: String?
    public init(timestamp: TimeInterval, modelID: String, modelVersion: String,
                inputRegion: CGRect, classifications: [VisualClassification],
                kind: Kind = .modelScores, diagnostic: String? = nil, backgroundLabel: String? = nil) {
        self.timestamp = timestamp; self.modelID = modelID; self.modelVersion = modelVersion
        self.inputRegion = inputRegion; self.classifications = classifications
        self.kind = kind; self.diagnostic = diagnostic; self.backgroundLabel = backgroundLabel
    }
}

public protocol VisualClassifying: Sendable {
    func modelInfo() async throws -> VisualModelInfo
    /// Return the full label scores, without filtering to the selected target.
    /// This contract requires finite scores in 0...1; other model outputs need
    /// an explicitly calibrated adapter rather than silent clamping.
    func classify(in image: RecognitionImage, crop: CGRect?) async throws -> VisualObservation
    /// Detection turned on at this frame time: the shopper reached the item's spot in
    /// the aisle. Called again after every pause or reactivation.
    func searchStarted(at timestamp: TimeInterval) async
}

public extension VisualClassifying { func searchStarted(at timestamp: TimeInterval) async {} }

/// Provisional demo thresholds; validate per model on the intended device.
public struct VisualRecognitionPolicy: Sendable {
    public let minimumScore: Float
    public let minimumMargin: Float
    public let requiredObservations: Int
    public let maximumGap: TimeInterval
    /// Target scores below this are noise: match confidence reports 0 (a cereal
    /// box that gets "onion" at 4% is not "a little bit onion").
    public let noiseFloor: Float
    public init(minimumScore: Float = 0.8, minimumMargin: Float = 0.2,
                requiredObservations: Int = 3, maximumGap: TimeInterval = 2,
                noiseFloor: Float = 0.1) {
        self.minimumScore = minimumScore.isFinite ? min(max(minimumScore, 0), 1) : 0.8
        self.minimumMargin = minimumMargin.isFinite ? min(max(minimumMargin, 0), 1) : 0.2
        self.requiredObservations = max(1, requiredObservations)
        self.maximumGap = maximumGap.isFinite ? max(0, maximumGap) : 2
        self.noiseFloor = noiseFloor.isFinite ? min(max(noiseFloor, 0), 1) : 0.1
    }

    /// Apple Vision behind the MVP taxonomy. It scores ~1,300 labels independently
    /// and rarely rates a specific produce label highly, so the selected item needs
    /// `minimumScore` and a 10-point lead over other produce labels (background
    /// excluded). Provisional: re-tune from device results for each item and lookalike.
    public static let appleVisionProduce = VisualRecognitionPolicy(minimumScore: 0.3, minimumMargin: 0.1)
}

public enum VisualRecognitionError: Error, LocalizedError, Equatable {
    case missingClassifier, missingModel, incompatibleModel, unsupportedClasses, invalidObservation
    public var errorDescription: String? {
        switch self {
        case .missingClassifier: return "This product needs a visual classifier. Supply one before scanning."
        case .missingModel: return "The compiled Core ML model is missing."
        case .incompatibleModel: return "The visual model does not match the catalog mapping or has no string class labels."
        case .unsupportedClasses: return "The visual model does not support this product's mapped classes."
        case .invalidObservation: return "The visual classifier returned invalid scores or inconsistent image/model metadata."
        }
    }
}
