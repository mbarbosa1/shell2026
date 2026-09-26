import Foundation
import ItemRecognition
import ProductDatabase

/// Immutable session adapter: one database read before capture, never one per frame.
/// Create a new instance after import, rule edits, or target/location changes.
public struct SwiftDataCatalogReader: CatalogReading {
    public let target: CatalogProductRecord
    public let candidates: [CatalogItemSnapshot]
    public let rule: DetectionActivationRuleSnapshot?
    public var targetVisualMetadata: VisualCatalogMetadata? { candidates.first { $0.id == target.id }?.visual }

    public static func load(from database: ProductDatabaseStore, productID: UUID,
                            location: CatalogLocation, visualMappings: VisualProductMappings? = nil) async throws -> Self {
        let records = try await database.sessionRecords(productID: productID, location: location)
        let mappings = try visualMappings ?? VisualProductMappings.bundled()
        return Self(records: records, mappings: mappings)
    }

    private init(records: CatalogSessionRecords, mappings: VisualProductMappings) {
        target = records.target
        let normalizer = TextNormalizer()
        candidates = records.candidates.map { record in
            let texts = [record.title] + record.aliases + (record.brand.map { [$0] } ?? [])
            return CatalogItemSnapshot(id: record.id, catalogKey: record.tcin, displayName: record.title,
                brand: record.brand, normalizedTerms: Set(texts.flatMap { normalizer.tokens(from: $0) }),
                visual: mappings.metadata(for: record.tcin))
        }
        rule = records.activation.map {
            DetectionActivationRuleSnapshot(targetItemID: $0.productID, landmarkID: $0.landmarkID,
                activateAfterMeters: $0.start, deactivateAfterMeters: $0.end,
                side: $0.side.flatMap(ShelfSide.init(rawValue:)), isInStore: $0.isInStore)
        }
    }

    public func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        guard targetItemID == target.id else { throw CatalogDatabaseError.missingProduct }
        return candidates
    }
    public func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        guard targetItemID == target.id else { throw CatalogDatabaseError.missingProduct }
        return rule
    }
}
