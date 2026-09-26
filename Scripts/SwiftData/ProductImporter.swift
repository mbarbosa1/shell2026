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
    static func importProducts(from data: Data, into context: ModelContext, save: Bool = true) throws -> Result {
        let file = try JSONDecoder().decode(ProductFileDTO.self, from: data)

        let existing = try context.fetch(FetchDescriptor<Product>())
        var byTcin = Dictionary(existing.map { ($0.tcin, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Result()

        for dto in file.products {
            // HARs are partial captures. Missing location data must not delete
            // products, their stable identity, or manually configured rules.
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
            apply(dto, to: product, in: context)
        }

        if save { try context.save() }
        return result
    }

    private static func apply(_ dto: ProductDTO, to p: Product, in context: ModelContext) {
        if let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { p.title = title }
        p.parentTitle = dto.parentTitle
        p.itemType = dto.itemType
        p.itemTypeId = dto.itemTypeId
        p.buyURL = dto.buyURL.flatMap(URL.init(string:))
        p.primaryImageURL = dto.primaryImageURL.flatMap(URL.init(string:))
        p.alternateImageURLs = (dto.alternateImageURLs ?? []).compactMap(URL.init(string:))
        p.imageAltText = dto.imageAltText
        p.currentPrice = dto.currentPrice
        p.regularPrice = dto.regularPrice
        p.formattedPrice = dto.formattedPrice
        p.unitPrice = dto.unitPrice
        p.unitPriceSuffix = dto.unitPriceSuffix
        p.quantityAvailable = dto.quantityAvailable
        p.soldOut = dto.soldOut

        // Preserve existing location identities. An incomplete capture is not a
        // removal instruction; explicit location retirement needs a separate workflow.
        for loc in dto.locations ?? [] {
            guard let aisle = loc.aisleNumber, let block = loc.block else { continue }
            let floor = loc.floor ?? "01"
            if !p.locations.contains(where: { $0.aisle == aisle && $0.block == block && $0.floor == floor }) {
                p.locations.append(StoreLocation(aisle: aisle, block: block, floor: floor))
            }
        }
    }
}
