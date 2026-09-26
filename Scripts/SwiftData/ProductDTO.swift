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

    struct Rating: Decodable {
        var label: String?
        var value: Double?
    }

    var tcin: String
    var title: String?
    var itemType: String?
    var itemTypeId: String?
    var departmentId: Int?
    var classId: Int?
    var parentTcin: String?
    var buyURL: String?
    var primaryImageURL: String?
    var alternateImageURLs: [String]?
    var imageAltText: String?

    var currentPrice: Double?
    var regularPrice: Double?
    var formattedPrice: String?
    var priceType: String?
    var formattedComparisonPrice: String?
    var unitPrice: String?
    var unitPriceSuffix: String?
    var saveDollar: Double?
    var savePercent: Double?

    var ratingAverage: Double?
    var ratingCount: Int?
    var ratingBreakdown: [Rating]?
    var badges: [String]?
    var promotions: [String]?

    var storeId: String?
    var storeName: String?
    var inStoreStatus: String?
    var pickupStatus: String?
    var shippingStatus: String?
    var deliveryStatus: String?
    var quantityAvailable: Double?
    var soldOut: Bool?

    var locations: [Location]?
    var searchTerms: [String]?
    var categories: [String]?
    var sourceFiles: [String]?

    /// True when at least one location has both an aisle and a block.
    var hasLocation: Bool {
        (locations ?? []).contains { $0.aisle != nil && $0.block != nil }
    }
}
