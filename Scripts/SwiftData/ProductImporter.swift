import Foundation
import SwiftData

/// Loads `products.json` (produced by `extract_har.py`) into SwiftData.
/// Re-running an import updates existing products by TCIN instead of duplicating them.
enum ProductImporter {
    struct Result {
        var inserted = 0
        var updated = 0
        var removed = 0
    }

    /// Imports `products.json` from the app bundle.
    @discardableResult
    static func importBundledProducts(into context: ModelContext, resource: String = "products") throws -> Result {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(resource).json"])
        }
        return try importProducts(from: url, into: context)
    }

    /// Imports only when the store is empty; call this on app launch to seed data once.
    static func seedIfNeeded(into context: ModelContext) throws {
        if try context.fetchCount(FetchDescriptor<Product>()) == 0 {
            try importBundledProducts(into: context)
        }
    }

    @discardableResult
    static func importProducts(from url: URL, into context: ModelContext) throws -> Result {
        try importProducts(from: Data(contentsOf: url), into: context)
    }

    @discardableResult
    static func importProducts(from data: Data, into context: ModelContext) throws -> Result {
        let file = try JSONDecoder().decode(ProductFileDTO.self, from: data)
        let rawByTcin = try rawPayloads(in: data)

        let existing = try context.fetch(FetchDescriptor<Product>())
        var byTcin = Dictionary(existing.map { ($0.tcin, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Result()

        for dto in file.products {
            // Only products with an aisle/block location belong in the database.
            guard dto.hasLocation else {
                if let stale = byTcin.removeValue(forKey: dto.tcin) {
                    context.delete(stale)
                    result.removed += 1
                }
                continue
            }
            let product: Product
            if let found = byTcin[dto.tcin] {
                product = found
                result.updated += 1
            } else {
                product = Product(tcin: dto.tcin, title: dto.title ?? dto.tcin)
                context.insert(product)
                byTcin[dto.tcin] = product
                result.inserted += 1
            }
            apply(dto, raw: rawByTcin[dto.tcin], to: product, in: context)
        }

        // Drop anything imported earlier that has no location.
        for product in byTcin.values where product.locations.isEmpty {
            context.delete(product)
            result.removed += 1
        }

        try context.save()
        return result
    }

    private static func apply(_ dto: ProductDTO, raw: Data?, to p: Product, in context: ModelContext) {
        p.title = dto.title ?? dto.tcin
        p.itemType = dto.itemType
        p.itemTypeId = dto.itemTypeId
        p.departmentId = dto.departmentId
        p.classId = dto.classId
        p.parentTcin = dto.parentTcin
        p.buyURL = dto.buyURL.flatMap(URL.init(string:))
        p.primaryImageURL = dto.primaryImageURL.flatMap(URL.init(string:))
        p.alternateImageURLs = (dto.alternateImageURLs ?? []).compactMap(URL.init(string:))
        p.imageAltText = dto.imageAltText

        p.currentPrice = dto.currentPrice
        p.regularPrice = dto.regularPrice
        p.formattedPrice = dto.formattedPrice
        p.priceType = dto.priceType
        p.formattedComparisonPrice = dto.formattedComparisonPrice
        p.unitPrice = dto.unitPrice
        p.unitPriceSuffix = dto.unitPriceSuffix
        p.saveDollar = dto.saveDollar
        p.savePercent = dto.savePercent

        p.ratingAverage = dto.ratingAverage
        p.ratingCount = dto.ratingCount
        p.ratingBreakdown = (dto.ratingBreakdown ?? []).compactMap { r in
            guard let label = r.label, let value = r.value else { return nil }
            return RatingScore(label: label, value: value)
        }
        p.badges = dto.badges ?? []
        p.promotions = dto.promotions ?? []

        p.storeId = dto.storeId
        p.storeName = dto.storeName
        p.inStoreStatus = dto.inStoreStatus
        p.pickupStatus = dto.pickupStatus
        p.shippingStatus = dto.shippingStatus
        p.deliveryStatus = dto.deliveryStatus
        p.quantityAvailable = dto.quantityAvailable
        p.soldOut = dto.soldOut

        for old in p.locations { context.delete(old) }
        p.locations = (dto.locations ?? []).compactMap { loc in
            guard let aisle = loc.aisle, let block = loc.block else { return nil }
            return StoreLocation(aisle: aisle, block: block, floor: loc.floor ?? "01")
        }

        p.searchTerms = dto.searchTerms ?? []
        p.categories = dto.categories ?? []
        p.sourceFiles = dto.sourceFiles ?? []
        p.rawJSON = raw
        p.updatedAt = .now
    }

    /// Pulls each product's untyped `raw` payload out as JSON data.
    private static func rawPayloads(in data: Data) throws -> [String: Data] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { return [:] }
        var out: [String: Data] = [:]
        for product in products {
            guard let tcin = product["tcin"] as? String, let raw = product["raw"] else { continue }
            out[tcin] = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        }
        return out
    }
}
