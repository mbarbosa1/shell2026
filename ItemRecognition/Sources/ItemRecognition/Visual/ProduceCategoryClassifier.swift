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

/// Broad MVP produce categories. `base` is the on-device model: Apple Vision now,
/// or a Create ML detector trained on the same labels later. When `cloud` is set
/// and local produce evidence is weak, one crop is sent for a cloud suggestion.
public actor ProduceCategoryClassifier: VisualClassifying {
    public static let modelID = "mvp.produce.categories.v1"
    private let base: any VisualClassifying
    private let taxonomy: ProduceTaxonomy
    private let cloud: (any CloudProduceLabeling)?
    private let cloudPolicy: CloudAssistPolicy
    private lazy var imageContext = CIContext()
    private var cloudRequests = 0

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

    public func classify(in image: RecognitionImage, crop: CGRect?) async throws -> VisualObservation {
        let result = try await base.classify(in: image, crop: crop)
        let version = try await version()
        let (local, background) = taxonomy.normalizeWithBackground(result.classifications)
        let localObservation = VisualObservation(timestamp: result.timestamp, modelID: Self.modelID,
            modelVersion: version, inputRegion: result.inputRegion, classifications: local,
            backgroundLabel: background)
        let localProduceScore = local.first { $0.identifier != "unknown" }?.score ?? 0
        guard let cloud, localProduceScore < cloudPolicy.localScoreBelow else { return localObservation }
        guard cloudRequests < cloudPolicy.maximumRequests else {
            return VisualObservation(timestamp: result.timestamp, modelID: Self.modelID, modelVersion: version,
                inputRegion: result.inputRegion, classifications: local,
                diagnostic: "Cloud assist request limit reached; using on-device result.", backgroundLabel: background)
        }
        cloudRequests += 1
        let fallback: String
        do {
            let jpeg = try CloudImageEncoder.jpeg(image, crop: result.inputRegion,
                maxDimension: cloudPolicy.maxImageDimension, context: imageContext)
            let suggestion = try await cloud.label(jpeg: jpeg, allowedLabels: taxonomy.identifiers.sorted())
            if taxonomy.identifiers.contains(suggestion.label), suggestion.confidence.isFinite,
               (0...1).contains(suggestion.confidence) {
                return VisualObservation(timestamp: result.timestamp, modelID: Self.modelID,
                    modelVersion: version, inputRegion: result.inputRegion,
                    classifications: [VisualClassification(identifier: suggestion.label, score: suggestion.confidence)],
                    kind: .cloudSuggestion, diagnostic: "Cloud model \(suggestion.model)")
            }
            fallback = CloudRecognitionError.invalidResponse.localizedDescription
        } catch {
            fallback = error.localizedDescription
        }
        return VisualObservation(timestamp: result.timestamp, modelID: Self.modelID, modelVersion: version,
            inputRegion: result.inputRegion, classifications: local,
            diagnostic: "Cloud assist unavailable; using on-device result. \(fallback)", backgroundLabel: background)
    }

    /// Stable across local and cloud observations so switching source does not
    /// reset temporal confirmation; a base-model change still does.
    private func version() async throws -> String {
        let local = try await base.modelInfo()
        return "taxonomy-\(taxonomy.version); local \(local.id) \(local.version); cloud \(cloud == nil ? "off" : "on")"
    }
}
