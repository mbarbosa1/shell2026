import Foundation

/// Immutable snapshot of the persisted activation rule for one target item
public struct DetectionActivationRuleSnapshot: Sendable, Hashable {
    public let targetItemID: UUID
    public let landmarkID: String
    public let activateAfterMeters: Double
    public let deactivateAfterMeters: Double
    public let side: ShelfSide?
    /// Whether this store carries the target item. The gate reads this boolean
    /// in `ActivationGate.isItemInStore(_:)`. `false` keeps detection off.
    public let isInStore: Bool

    public init(
        targetItemID: UUID,
        landmarkID: String,
        activateAfterMeters: Double,
        deactivateAfterMeters: Double,
        side: ShelfSide? = nil,
        isInStore: Bool = true
    ) {
        self.targetItemID = targetItemID
        self.landmarkID = landmarkID
        self.activateAfterMeters = activateAfterMeters
        self.deactivateAfterMeters = deactivateAfterMeters
        self.side = side
        self.isInStore = isInStore
    }
}
