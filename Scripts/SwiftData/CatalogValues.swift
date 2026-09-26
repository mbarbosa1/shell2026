import Foundation

public struct CatalogLocation: Sendable, Hashable, Identifiable {
    public let floor: String
    public let block: String
    public let aisle: Int
    public var id: String { "\(floor)|\(block)|\(aisle)" }
    public var label: String { "\(block)\(aisle) (floor \(floor))" }
    public init(floor: String, block: String, aisle: Int) {
        self.floor = floor; self.block = block; self.aisle = aisle
    }
}

public struct CatalogProductRecord: Sendable, Identifiable {
    public let id: UUID
    public let tcin: String
    public let title: String
    public let brand: String?
    public let aliases: [String]
    public let locations: [CatalogLocation]
}

public struct CatalogActivationRecord: Sendable {
    public let productID: UUID
    public let landmarkID: String
    public let start: Double
    public let end: Double
    public let side: String?
    public let isInStore: Bool
}

public struct CatalogSessionRecords: Sendable {
    public let target: CatalogProductRecord
    public let candidates: [CatalogProductRecord]
    public let activation: CatalogActivationRecord?
}

public enum CatalogDatabaseError: Error, LocalizedError, Equatable {
    case missingProduct
    case invalidLocation
    case invalidRule
    case invalidProductID
    public var errorDescription: String? {
        switch self {
        case .missingProduct: return "The selected product is not in the catalog."
        case .invalidLocation: return "Select a location currently registered for this product."
        case .invalidRule: return "Enter a landmark, valid side, and finite distances with 0 ≤ start ≤ end."
        case .invalidProductID: return "Product TCINs must be nonempty and unique within an import."
        }
    }
}
