import Foundation

/// Immutable snapshot of one catalog record the database branch has stored
public struct CatalogItemSnapshot: Sendable, Hashable {
    public let id: UUID
    public let catalogKey: String
    public let displayName: String
    public let brand: String?
    public let normalizedTerms: Set<String>
    public let visual: VisualCatalogMetadata?
    /// Catalog `itemType`, such as "Fruit" or "Crackers". Nil when the caller did not supply one.
    public let itemType: String?

    /// Loose produce is recognized by appearance. Packaged goods stay on text.
    public var recognizesByAppearance: Bool {
        guard let itemType else { return false }
        let value = itemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "fruit" || value.hasPrefix("vegetable")
    }

    public init(
        id: UUID,
        catalogKey: String,
        displayName: String,
        brand: String?,
        normalizedTerms: Set<String>,
        visual: VisualCatalogMetadata? = nil,
        itemType: String? = nil
    ) {
        self.id = id
        self.catalogKey = catalogKey
        self.displayName = displayName
        self.brand = brand
        self.normalizedTerms = normalizedTerms
        self.visual = visual
        self.itemType = itemType
    }
}

/// Read-only access to the records the database branch persists
public protocol CatalogReading: Sendable {
    /// Catalog records the matcher should compare against for the given target.
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot]
    /// The persisted activation rule for the given target
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot?
}
