import Foundation

/// When a product's distance may be measured: only after the shopper says Yes to recognition's
/// "Is this …?" (user decision, September 27, 2026). Before that the product can be followed
/// across frames, so its box is current when the Yes comes, but no distance is worked out.
public struct MeasurementGate: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Recognition confirmed this item and is asking the shopper. Follow it; don't measure.
        case following(UUID)
        /// The shopper said Yes to this item. Measure it.
        case measuring(UUID)
    }

    public private(set) var state = State.idle

    public init() {}

    public var isMeasuring: Bool {
        if case .measuring = state { true } else { false }
    }

    /// The item being followed or measured.
    public var item: UUID? {
        switch state {
        case .idle: nil
        case .following(let item), .measuring(let item): item
        }
    }

    /// Recognition confirmed `item`. True when that starts following it. A repeat for the item
    /// already followed or measured changes nothing, so a settled answer arriving on every frame
    /// doesn't restart anything. Another item replaces the current one.
    public mutating func confirmed(_ item: UUID) -> Bool {
        guard self.item != item else { return false }
        state = .following(item)
        return true
    }

    /// The shopper said Yes to `item`. True when that starts measuring: only for the item being
    /// followed, so a late Yes for an earlier item measures nothing.
    public mutating func accepted(_ item: UUID) -> Bool {
        guard state == .following(item) else { return false }
        state = .measuring(item)
        return true
    }

    /// The shopper said No, the product was lost, or shopping ended.
    public mutating func reset() {
        state = .idle
    }
}
