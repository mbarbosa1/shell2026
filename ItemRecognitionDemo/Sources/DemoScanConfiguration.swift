import Foundation
import ItemRecognition

struct DemoScanConfiguration: Identifiable, Sendable {
    let id = UUID()
    let targetID: UUID
    let title: String
    let catalog: any CatalogReading
    let rule: DetectionActivationRuleSnapshot?
    let usesDatabase: Bool
    let catalogKey: String?
    let visual: VisualCatalogMetadata?

    init(targetID: UUID, title: String, catalog: any CatalogReading,
         rule: DetectionActivationRuleSnapshot?, usesDatabase: Bool,
         catalogKey: String? = nil, visual: VisualCatalogMetadata? = nil) {
        self.targetID = targetID; self.title = title; self.catalog = catalog
        self.rule = rule; self.usesDatabase = usesDatabase
        self.catalogKey = catalogKey; self.visual = visual
    }

    static var ocrOnly: Self {
        let catalog = DemoCatalog()
        return Self(targetID: DemoCatalog.targetID, title: "Text extraction only", catalog: catalog,
                    rule: catalog.rule, usesDatabase: false)
    }
}

/// Development settings for `ItemRecognition/CloudProxy`. The token only
/// authenticates this app to that proxy; no provider API key belongs here.
enum DemoCloudAssist {
    static let enabledKey = "cloudAssist.enabled"
    static let endpointKey = "cloudAssist.endpoint"
    static let tokenKey = "cloudAssist.token"

    static func labeler(_ defaults: UserDefaults = .standard) -> (any CloudProduceLabeling)? {
        guard defaults.bool(forKey: enabledKey),
              let text = defaults.string(forKey: endpointKey),
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return HTTPCloudProduceLabeler(endpoint: url, token: defaults.string(forKey: tokenKey))
    }

    static func visualPolicy(for metadata: VisualCatalogMetadata) -> VisualRecognitionPolicy {
        metadata.modelID == ProduceCategoryClassifier.modelID ? .appleVisionProduce : VisualRecognitionPolicy()
    }

    static func visualClassifier(for metadata: VisualCatalogMetadata) throws -> any VisualClassifying {
        switch metadata.modelID {
        case ProduceCategoryClassifier.modelID:
            // Ask the cloud only when on-device evidence would not pass on its own.
            let cloudPolicy = CloudAssistPolicy(localScoreBelow: VisualRecognitionPolicy.appleVisionProduce.minimumScore)
            return try ProduceCategoryClassifier(base: VisionImageClassifier(), cloud: labeler(), cloudPolicy: cloudPolicy)
        case VisionImageClassifier.modelID:
            return VisionImageClassifier()
        default:
            throw VisualRecognitionError.missingClassifier
        }
    }
}

private struct DemoCatalog: CatalogReading {
    static let targetID = UUID(uuidString: "F622F98D-84A9-472F-9AFD-A0FC96B137CA")!
    let rule = DetectionActivationRuleSnapshot(targetItemID: Self.targetID, landmarkID: "demo-aisle",
                                               activateAfterMeters: 3, deactivateAfterMeters: 20)
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? { rule }
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        [CatalogItemSnapshot(id: Self.targetID, catalogKey: "demo", displayName: "Text extraction only", brand: nil, normalizedTerms: [])]
    }
}
