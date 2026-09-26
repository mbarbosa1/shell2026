import Foundation

/// Immutable snapshot of one catalog record the database branch has stored.
///
/// Matching against these snapshots is a later slice. The type exists here so
/// `CatalogReading` matches the agreed protocol shape.
public struct CatalogItemSnapshot: Sendable, Hashable {
    public let id: UUID
    public let catalogKey: String
    public let displayName: String
    public let brand: String?
    public let normalizedTerms: Set<String>

    public init(
        id: UUID,
        catalogKey: String,
        displayName: String,
        brand: String?,
        normalizedTerms: Set<String>
    ) {
        self.id = id
        self.catalogKey = catalogKey
        self.displayName = displayName
        self.brand = brand
        self.normalizedTerms = normalizedTerms
    }
}

/// Read-only access to the records the database branch persists.
///
/// The database branch supplies the concrete adapter (it may use
/// `@ModelActor` internally). Recognition code depends only on this protocol
/// and the immutable snapshots it returns. Nothing in this package touches a
/// `ModelContext`.
public protocol CatalogReading: Sendable {
    /// Catalog records the matcher should compare against for the given target.
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot]

    /// The persisted activation rule for the given target, or `nil` when the
    /// database branch has not registered one. `nil` keeps detection off.
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot?
}
