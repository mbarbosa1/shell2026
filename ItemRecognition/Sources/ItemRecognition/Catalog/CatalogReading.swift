import Foundation

/// Immutable snapshot of one catalog record the database branch has stored
public struct CatalogItemSnapshot: Sendable, Hashable {
    public let id: UUID
    public let catalogKey: String
    public let displayName: String
    public let brand: String?
    public let normalizedTerms: Set<String>
    public let visual: VisualCatalogMetadata?

    public init(
        id: UUID,
        catalogKey: String,
        displayName: String,
        brand: String?,
        normalizedTerms: Set<String>,
        visual: VisualCatalogMetadata? = nil
    ) {
        self.id = id
        self.catalogKey = catalogKey
        self.displayName = displayName
        self.brand = brand
        self.normalizedTerms = normalizedTerms
        self.visual = visual
    }
}

/// Read-only access to the records the database branch persists
public protocol CatalogReading: Sendable {
    /// Catalog records the matcher should compare against for the given target.
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot]
    /// The persisted activation rule for the given target
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot?
}
