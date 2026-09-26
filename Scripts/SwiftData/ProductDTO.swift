import Foundation

// MARK: - JSON shape written by extract_har.py

struct ProductFileDTO: Decodable {
    var generatedAt: String?
    var sources: [String]?
    var productCount: Int?
    var products: [ProductDTO]
}

struct ProductDTO: Decodable {
    struct Location: Decodable {
        var aisle: Int?
        var block: String?
        var floor: String?
    }

    var tcin: String
    var title: String?
    var parentTitle: String?
    var itemType: String?
    var itemTypeId: String?
    var buyURL: String?
    var primaryImageURL: String?
    var alternateImageURLs: [String]?
    var imageAltText: String?
    var currentPrice: Double?
    var regularPrice: Double?
    var formattedPrice: String?
    var unitPrice: String?
    var unitPriceSuffix: String?
    var quantityAvailable: Double?
    var soldOut: Bool?
    var locations: [Location]?

    /// True when at least one location has both an aisle and a block.
    var hasLocation: Bool {
        (locations ?? []).contains { $0.aisle != nil && $0.block != nil }
    }
}
