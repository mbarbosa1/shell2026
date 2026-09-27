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
        /// Combined aisle identifier from the scraper, for example "A23".
        var aisle: String?
        var floor: String?

        // Keep the existing persistence schema compatible with saved catalogs.
        var block: String? {
            guard let aisle else { return nil }
            let prefix = String(aisle.prefix { $0.isLetter })
            return prefix.isEmpty ? nil : prefix
        }
        var aisleNumber: Int? {
            guard let aisle, let block else { return nil }
            return Int(aisle.dropFirst(block.count))
        }

        private enum CodingKeys: String, CodingKey { case aisle, block, floor }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            floor = try values.decodeIfPresent(String.self, forKey: .floor)
            if let combined = try? values.decode(String.self, forKey: .aisle) {
                aisle = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let number = try values.decodeIfPresent(Int.self, forKey: .aisle),
                      let block = try values.decodeIfPresent(String.self, forKey: .block) {
                aisle = "\(block)\(number)"
            } else {
                aisle = nil
            }
        }
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

    /// True when at least one location has a valid combined aisle identifier.
    var hasLocation: Bool {
        (locations ?? []).contains { $0.aisleNumber != nil && $0.block != nil }
    }
}
