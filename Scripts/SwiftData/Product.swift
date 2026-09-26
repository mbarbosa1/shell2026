import Foundation
import SwiftData

/// A Target product scraped from the HAR captures, keyed by TCIN.
@Model
final class Product {
    @Attribute(.unique) var tcin: String
    var title: String
    /// Title of the variation group, e.g. "Milk - Good & Gather™" for the 2% gallon.
    var parentTitle: String?
    var itemType: String?
    var itemTypeId: String?

    var buyURL: URL?
    var primaryImageURL: URL?
    var alternateImageURLs: [URL]
    var imageAltText: String?

    /// Price at the store the HAR was captured against. `formattedPrice` is Target's
    /// display string, which can be a range ("$1.19 - $3.99") for variation groups.
    var currentPrice: Double?
    var regularPrice: Double?
    var formattedPrice: String?
    var unitPrice: String?
    var unitPriceSuffix: String?

    /// Stock at the store the HAR was captured against.
    var quantityAvailable: Double?
    var soldOut: Bool?

    /// Where the product sits in the store. Some products are stocked in several spots.
    @Relationship(deleteRule: .cascade, inverse: \StoreLocation.product)
    var locations: [StoreLocation] = []

    init(tcin: String, title: String) {
        self.tcin = tcin
        self.title = title
        self.alternateImageURLs = []
    }

    var isOnSale: Bool {
        guard let currentPrice, let regularPrice else { return false }
        return currentPrice < regularPrice
    }
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
