import Foundation
import SwiftData

/// A Target product scraped from the HAR captures, keyed by TCIN.
@Model
final class Product {
    @Attribute(.unique) var tcin: String
    var title: String
    var itemType: String?
    var itemTypeId: String?
    var departmentId: Int?
    var classId: Int?
    var parentTcin: String?
    var buyURL: URL?
    var primaryImageURL: URL?
    var alternateImageURLs: [URL]
    var imageAltText: String?

    // Pricing
    var currentPrice: Double?
    var regularPrice: Double?
    var formattedPrice: String?
    var priceType: String?
    var formattedComparisonPrice: String?
    var unitPrice: String?
    var unitPriceSuffix: String?
    var saveDollar: Double?
    var savePercent: Double?

    // Ratings and merchandising
    var ratingAverage: Double?
    var ratingCount: Int?
    var ratingBreakdown: [RatingScore]
    var badges: [String]
    var promotions: [String]

    // Store availability (store the HAR was captured against)
    var storeId: String?
    var storeName: String?
    var inStoreStatus: String?
    var pickupStatus: String?
    var shippingStatus: String?
    var deliveryStatus: String?
    var quantityAvailable: Double?
    var soldOut: Bool?

    /// Where the product sits in the store. Some products are stocked in several spots.
    @Relationship(deleteRule: .cascade, inverse: \StoreLocation.product)
    var locations: [StoreLocation] = []

    var searchTerms: [String]
    var categories: [String]
    var sourceFiles: [String]

    /// The full merged API payload, so no field from the HAR is lost.
    @Attribute(.externalStorage) var rawJSON: Data?

    var updatedAt: Date

    init(tcin: String, title: String) {
        self.tcin = tcin
        self.title = title
        self.alternateImageURLs = []
        self.ratingBreakdown = []
        self.badges = []
        self.promotions = []
        self.searchTerms = []
        self.categories = []
        self.sourceFiles = []
        self.updatedAt = .now
    }

    /// Primary location as shown in the Target app, e.g. "G44".
    var locationLabel: String? {
        locations.sorted { ($0.block, $0.aisle) < ($1.block, $1.aisle) }.first?.label
    }
}

/// One aisle/block/floor position of a product in the store.
@Model
final class StoreLocation {
    var aisle: Int
    var block: String
    var floor: String
    var product: Product?

    init(aisle: Int, block: String, floor: String) {
        self.aisle = aisle
        self.block = block
        self.floor = floor
    }

    var label: String { "\(block)\(aisle)" }
}

struct RatingScore: Codable, Hashable {
    var label: String
    var value: Double
}
