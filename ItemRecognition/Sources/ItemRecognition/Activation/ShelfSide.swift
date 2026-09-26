import Foundation

/// Which side of the aisle the target item is expected on, relative to the
/// direction of travel along the aisle edge.
public enum ShelfSide: String, Codable, Sendable, Hashable {
    case left
    case right
}
