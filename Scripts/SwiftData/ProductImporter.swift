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

    /// Bump when `apply` starts filling in something new (like `brand` and `size`), so products
    /// saved by an older build are imported again.
    static let revision = 2

    /// Imports the bundled `products.json` on first launch, and again whenever its `generatedAt`
    /// or `revision` changes (after `Scripts/run.sh` and a rebuild). Call on app launch.
    static func importIfChanged(into context: ModelContext, resource: String = "products") {
        let versionKey = "productCatalogGeneratedAt"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ProductFileDTO.self, from: data)
        else {
            print("📦 Product catalog: \(resource).json is missing from the app bundle")
            return
        }
        let version = "\(file.generatedAt ?? "") r\(revision)"
        let isEmpty = ((try? context.fetchCount(FetchDescriptor<Product>())) ?? 0) == 0
        guard isEmpty || UserDefaults.standard.string(forKey: versionKey) != version else { return }
        do {
            let result = try importProducts(from: data, into: context)
            UserDefaults.standard.set(version, forKey: versionKey)
            print("📦 Product catalog loaded (\(version)): \(result.inserted) new, \(result.updated) updated, \(result.removed) removed")
        } catch {
            print("📦 Product catalog failed to load: \(error)")
        }
    }

    @discardableResult
    static func importProducts(from url: URL, into context: ModelContext) throws -> Result {
        try importProducts(from: Data(contentsOf: url), into: context)
    }

    @discardableResult
    static func importProducts(from data: Data, into context: ModelContext) throws -> Result {
        let file = try JSONDecoder().decode(ProductFileDTO.self, from: data)

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
            apply(dto, to: product, in: context)
        }

        // Drop anything imported earlier that has no location.
        for product in byTcin.values where product.locations.isEmpty {
            context.delete(product)
            result.removed += 1
        }

        try context.save()
        return result
    }

    private static func apply(_ dto: ProductDTO, to p: Product, in context: ModelContext) {
        p.title = dto.title ?? dto.tcin
        p.parentTitle = dto.parentTitle
        p.itemType = dto.itemType
        p.itemTypeId = dto.itemTypeId
        p.brand = brand(fromTitle: p.title)
        p.size = size(fromTitle: p.title)
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

        for old in p.locations { context.delete(old) }
        p.locations = (dto.locations ?? []).compactMap { loc in
            guard let aisle = loc.aisle, let block = loc.block else { return nil }
            return StoreLocation(aisle: aisle, block: block, floor: loc.floor ?? "01")
        }
    }

    // MARK: Brand and size from the title

    // Target's captures have no brand or size fields, so they come from the title:
    // "Banana Nut Granola - 12oz - Good & Gather™" → size "12oz", brand "Good & Gather™".

    /// A leading amount and unit: "12oz", "1gal", "0.8-1.4lbs", "15oz/8ct", "1pt".
    private static let sizePattern = #"^\d[\d./-]*\s*(fl\.? ?oz|oz|gal|ct|lbs?|pk|ml|l|g|kg|qt|pt|dozen|count)\b"#

    private static func titleParts(_ title: String) -> [String] {
        title.replacingOccurrences(of: " – ", with: " - ")
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSize(_ text: String) -> Bool {
        text.range(of: sizePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func size(fromTitle title: String) -> String? {
        let parts = titleParts(title).dropFirst()
        if let size = parts.first(where: isSize) { return size }
        if parts.contains(where: { $0.caseInsensitiveCompare("each") == .orderedSame }) { return "each" }
        if parts.contains(where: { $0.localizedCaseInsensitiveContains("price per lb") }) { return "per lb" }
        return nil
    }

    /// Only the store brand Target puts last; name brands lead the title and can't be split off reliably.
    static func brand(fromTitle title: String) -> String? {
        let parts = titleParts(title)
        guard parts.count >= 3, let last = parts.last else { return nil }
        let brand = last.components(separatedBy: ":")[0]
            .replacingOccurrences(of: "(Packaging May Vary)", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !brand.isEmpty, !isSize(brand), !brand.localizedCaseInsensitiveContains("price per") else { return nil }
        return brand
    }
}
