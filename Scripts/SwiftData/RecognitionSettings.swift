import Foundation
import SwiftData

/// Database-owned identity. Product names continue to live only on Product.
/// This additive table leaves the existing scraped Product schema unchanged.
@Model
final class ProductRecognitionProfile {
    @Attribute(.unique) var tcin: String
    var recognitionID: UUID
    var brand: String?
    var aliases: [String]

    init(tcin: String) {
        self.tcin = tcin
        recognitionID = UUID()
        aliases = []
    }
}

/// Survey/development configuration, never inferred from an aisle or stock count.
/// References TCIN and location values, so re-importing location objects cannot
/// cascade-delete rules. The database verifies that the location still exists.
@Model
final class ProductActivationSettings {
    @Attribute(.unique) var key: String
    var tcin: String
    var floor: String
    var block: String
    var aisle: Int
    var landmarkID: String
    var activateAfterMeters: Double
    var deactivateAfterMeters: Double
    var side: String?
    var isInStore: Bool
    var enabled: Bool

    init(key: String, tcin: String, location: CatalogLocation,
         landmarkID: String, start: Double, end: Double, side: String?, isInStore: Bool) {
        self.key = key; self.tcin = tcin
        floor = location.floor; block = location.block; aisle = location.aisle
        self.landmarkID = landmarkID; activateAfterMeters = start; deactivateAfterMeters = end
        self.side = side; self.isInStore = isInStore; enabled = true
    }
}

/// Tracks imports for the single-store demo catalog.
@Model
final class CatalogImportState {
    @Attribute(.unique) var key: String
    var contentDigest: String
    var importedAt: Date
    init() {
        key = "catalog"; contentDigest = ""; importedAt = .distantPast
    }
}
