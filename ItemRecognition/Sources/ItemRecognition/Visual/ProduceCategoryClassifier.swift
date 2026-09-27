import CoreGraphics
import CoreImage
import Foundation

/// Shared broad MVP taxonomy. Variety, brand, size and organic status are not classes.
public struct ProduceTaxonomy: Decodable, Sendable {
    public let version: Int
    public let classes: [String: [String]]
    public let ignoredParentLabels: Set<String>
    public var identifiers: Set<String> { Set(classes.keys).union(["unknown"]) }

    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "produce-taxonomy", withExtension: "json") else {
            throw VisualRecognitionError.incompatibleModel
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Words that describe loose produce without making it a packaged product.
    static let produceDescriptors: Set<String> = [
        "fresh", "organic", "red", "yellow", "white", "sweet", "green", "large", "small", "medium",
        "baby", "mini", "ripe", "whole", "loose", "bunch", "bag", "each", "seedless",
        "gala", "fuji", "honeycrisp", "granny", "smith", "navel", "russet", "roma",
    ]

    /// The produce class a grocery-list name refers to: "Bananas" → `banana`,
    /// "Red onions" → `onion`. Nil unless every other word only describes the
    /// produce, so "Apple juice", "Onion powder", and "Potato chips" stay on text.
    public func classID(forItemName name: String) -> String? {
        let aliases = Dictionary(classes.flatMap { key, values in values.map { ($0, key) } }, uniquingKeysWith: { a, _ in a })
        var found: String?
        for word in TextNormalizer().tokens(from: name) where !word.contains(" ") {
            if let match = ([word] + ItemTypeAnchor.singulars(of: word)).lazy.compactMap({ aliases[$0] }).first {
                guard found == nil || found == match else { return nil }
                found = match
            } else if !Self.produceDescriptors.contains(word), !word.allSatisfy(\.isNumber) {
                return nil
            }
        }
        return found
    }

    public func normalize(_ predictions: [VisualClassification]) -> [VisualClassification] {
        normalizeWithBackground(predictions).classifications
    }

    /// Also returns the raw non-produce label that set the `unknown` score.
    public func normalizeWithBackground(_ predictions: [VisualClassification])
        -> (classifications: [VisualClassification], backgroundLabel: String?) {
        let aliases = Dictionary(uniqueKeysWithValues: classes.flatMap { key, values in values.map { ($0, key) } })
        var scores: [String: Float] = [:]
        var background: VisualClassification?
        for prediction in predictions where prediction.score.isFinite && (0...1).contains(prediction.score) {
            guard !ignoredParentLabels.contains(prediction.identifier) else { continue }
            let label = aliases[prediction.identifier] ?? "unknown"
            if label == "unknown", prediction.score > (background?.score ?? 0) { background = prediction }
            scores[label] = max(scores[label] ?? 0, prediction.score)
        }
        let classifications: [VisualClassification] = scores
            .map { VisualClassification(identifier: $0.key, score: $0.value) }
            .sorted { (a: VisualClassification, b: VisualClassification) -> Bool in
                a.score == b.score ? a.identifier < b.identifier : a.score > b.score
            }
        return (classifications, background?.identifier)
    }
}

/// Gemini use for one item scan, for a tester's display.
public struct CloudAssistUsage: Sendable, Equatable {
    public let calls: Int
    public let limit: Int
    /// Apple Vision time left before Gemini may be asked, as of the latest frame.
    /// Nil when no call remains or no frame has been classified yet.
    public let secondsUntilCall: TimeInterval?
    public let lastLabel: CloudProduceLabel?
    /// Why the last call gave no label, in plain words. Nil after a label.
    public let lastFailure: String?
    /// Wall-clock time of the last call.
    public let lastSeconds: TimeInterval?
}

/// Broad MVP produce categories. `base` (Apple Vision now, or a Create ML detector
/// later) classifies every frame. With `cloud` set, Gemini is asked only when Apple
/// Vision has not produced a question in time (see `CloudAssistPolicy`). The call
/// runs on the frame it describes; a Gemini label is used once and never reused
/// for later frames.
public actor ProduceCategoryClassifier: VisualClassifying {
    public static let modelID = "mvp.produce.categories.v1"
    private let base: any VisualClassifying
    private let taxonomy: ProduceTaxonomy
    private let cloud: (any CloudProduceLabeling)?
    private let cloudPolicy: CloudAssistPolicy
    private lazy var imageContext = CIContext()
    private var cloudRequests = 0
    private var cloudInFlight = false
    /// Frame time Apple Vision's current solo window started: detection turning on, or the first frame after a call.
    private var windowStart: TimeInterval?
    private var latestFrame: TimeInterval?
    private var lastLabel: CloudProduceLabel?
    private var lastFailure: String?
    private var lastSeconds: TimeInterval?

    private var callLimit: Int { min(cloudPolicy.maximumRequestsPerItem, cloudPolicy.maximumRequests) }

    public init(base: any VisualClassifying = VisionImageClassifier(),
                cloud: (any CloudProduceLabeling)? = nil,
                cloudPolicy: CloudAssistPolicy = CloudAssistPolicy()) throws {
        self.base = base
        self.cloud = cloud
        self.cloudPolicy = cloudPolicy
        taxonomy = try ProduceTaxonomy.bundled()
    }

    public func modelInfo() async throws -> VisualModelInfo {
        VisualModelInfo(id: Self.modelID, version: try await version(),
                        supportedClassIDs: taxonomy.identifiers)
    }

    public func searchStarted(at timestamp: TimeInterval) async {
        windowStart = timestamp
    }

    public func usage() -> CloudAssistUsage {
        let remaining: TimeInterval? = {
            guard cloud != nil, cloudRequests < callLimit, let windowStart, let latestFrame else { return nil }
            return max(0, cloudPolicy.appleVisionSeconds - (latestFrame - windowStart))
        }()
        return CloudAssistUsage(calls: cloudRequests, limit: cloud == nil ? 0 : callLimit, secondsUntilCall: remaining,
                                lastLabel: lastLabel, lastFailure: lastFailure, lastSeconds: lastSeconds)
    }

    public func classify(in image: RecognitionImage, crop: CGRect?) async throws -> VisualObservation {
        let version = try await version()
        let region = crop ?? CGRect(origin: .zero, size: image.imageResolution)
        latestFrame = image.timestamp
        if windowStart == nil { windowStart = image.timestamp }
        guard let cloud, !cloudInFlight, cloudRequests < callLimit, let windowStart,
              image.timestamp - windowStart >= cloudPolicy.appleVisionSeconds else {
            return try await localObservation(image: image, crop: crop, version: version)
        }
        cloudInFlight = true
        cloudRequests += 1
        let started = Date()
        // Apple Vision's next solo window starts on the first frame after the answer.
        defer { cloudInFlight = false; self.windowStart = nil; lastSeconds = Date().timeIntervalSince(started) }
        do {
            let jpeg = try CloudImageEncoder.jpeg(image, crop: region,
                maxDimension: cloudPolicy.maxImageDimension, context: imageContext)
            let suggestion = try await cloud.label(jpeg: jpeg, allowedLabels: taxonomy.identifiers.sorted())
            if taxonomy.identifiers.contains(suggestion.label), suggestion.confidence.isFinite,
               (0...1).contains(suggestion.confidence) {
                lastLabel = suggestion; lastFailure = nil
                return VisualObservation(timestamp: image.timestamp, modelID: Self.modelID,
                    modelVersion: version, inputRegion: region,
                    classifications: [VisualClassification(identifier: suggestion.label, score: suggestion.confidence)],
                    kind: .cloudSuggestion, diagnostic: "Cloud model \(suggestion.model)")
            }
            lastLabel = nil; lastFailure = CloudRecognitionError.invalidResponse.localizedDescription
        } catch {
            lastLabel = nil; lastFailure = error.localizedDescription
        }
        return try await localObservation(image: image, crop: crop, version: version,
            diagnostic: "Cloud assist unavailable; using on-device result. \(lastFailure ?? "")")
    }

    private func localObservation(image: RecognitionImage, crop: CGRect?, version: String,
                                  diagnostic: String? = nil) async throws -> VisualObservation {
        let result = try await base.classify(in: image, crop: crop)
        let (local, background) = taxonomy.normalizeWithBackground(result.classifications)
        return VisualObservation(timestamp: result.timestamp, modelID: Self.modelID, modelVersion: version,
            inputRegion: result.inputRegion, classifications: local, diagnostic: diagnostic, backgroundLabel: background)
    }

    /// Stable across local and cloud observations so switching source does not
    /// reset temporal confirmation; a base-model change still does.
    private func version() async throws -> String {
        let local = try await base.modelInfo()
        return "taxonomy-\(taxonomy.version); local \(local.id) \(local.version); cloud \(cloud == nil ? "off" : "on")"
    }
}
