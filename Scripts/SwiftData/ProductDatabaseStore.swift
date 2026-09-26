import CryptoKit
import Foundation
import SwiftData

/// Database implementation independent of activation, OCR, or a particular UI.
/// All model access stays on this actor; only immutable values leave it.
@ModelActor
public actor ProductDatabaseStore {
    public init(inMemory: Bool = false, storageURL: URL? = nil) throws {
        let schema = Schema([Product.self, StoreLocation.self, ProductRecognitionProfile.self,
                             ProductActivationSettings.self, CatalogImportState.self])
        let configuration: ModelConfiguration
        if let storageURL {
            configuration = ModelConfiguration("ProductCatalog", schema: schema, url: storageURL)
        } else {
            configuration = ModelConfiguration("ProductCatalog", schema: schema, isStoredInMemoryOnly: inMemory)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    /// Imports the single-store catalog; a digest skips unchanged imports on launch.
    @discardableResult
    public func importProducts(_ data: Data) throws -> Bool {
        let file = try JSONDecoder().decode(ProductFileDTO.self, from: data)
        let ids = file.products.map(\.tcin)
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }), Set(ids).count == ids.count else {
            throw CatalogDatabaseError.invalidProductID
        }
        let existingState = try modelContext.fetch(FetchDescriptor<CatalogImportState>()).first
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if existingState?.contentDigest == digest { return false }
        do {
            try ProductImporter.importProducts(from: data, into: modelContext, save: false)
            var known = Set(try modelContext.fetch(FetchDescriptor<ProductRecognitionProfile>()).map(\.tcin))
            for product in try modelContext.fetch(FetchDescriptor<Product>()) where known.insert(product.tcin).inserted {
                modelContext.insert(ProductRecognitionProfile(tcin: product.tcin))
            }
            let state = existingState ?? CatalogImportState()
            if existingState == nil { modelContext.insert(state) }
            state.contentDigest = digest; state.importedAt = Date()
            try modelContext.save()
            return true
        } catch { modelContext.rollback(); throw error }
    }

    public func products() throws -> [CatalogProductRecord] {
        let profiles = try profileMap()
        return try modelContext.fetch(FetchDescriptor<Product>(sortBy: [SortDescriptor(\Product.title)]))
            .compactMap { product in profiles[product.tcin].map { record(product, profile: $0) } }
    }

    /// Read target, candidate set, and activation in one actor operation. Selection
    /// is explicit; we never substitute the first location of a multi-location item.
    public func sessionRecords(productID: UUID, location: CatalogLocation) throws -> CatalogSessionRecords {
        let profiles = try profileMap()
        guard let profile = profiles.values.first(where: { $0.recognitionID == productID }) else {
            throw CatalogDatabaseError.missingProduct
        }
        let products = try modelContext.fetch(FetchDescriptor<Product>())
        guard let target = products.first(where: { $0.tcin == profile.tcin }) else { throw CatalogDatabaseError.missingProduct }
        guard target.locations.contains(where: { matches($0, location) }) else { throw CatalogDatabaseError.invalidLocation }
        let settings = try activationSettings(tcin: target.tcin, location: location)
        var activation: CatalogActivationRecord?
        if let settings, settings.enabled {
            try validateRule(landmark: settings.landmarkID, start: settings.activateAfterMeters,
                             end: settings.deactivateAfterMeters, side: settings.side)
            activation = CatalogActivationRecord(productID: productID, landmarkID: settings.landmarkID,
                start: settings.activateAfterMeters, end: settings.deactivateAfterMeters,
                side: settings.side, isInStore: settings.isInStore)
        }
        let targetRecord = record(target, profile: profile)
        // Same aisle/floor only. Keep all these candidates so a competing variant
        // is not silently omitted; no database reads happen in frame processing.
        let neighbors = products.filter { $0.tcin != target.tcin && $0.locations.contains(where: { matches($0, location) }) }
            .sorted { $0.tcin < $1.tcin }
            .compactMap { product in profiles[product.tcin].map { record(product, profile: $0) } }
        return CatalogSessionRecords(target: targetRecord, candidates: [targetRecord] + neighbors, activation: activation)
    }

    public func saveActivation(productID: UUID, location: CatalogLocation,
                               landmark: String, start: Double, end: Double, side: String?, isInStore: Bool) throws {
        let clean = landmark.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRule(landmark: clean, start: start, end: end, side: side)
        let records = try sessionRecords(productID: productID, location: location)
        let key = Self.ruleKey(tcin: records.target.tcin, location: location)
        do {
            let old = try activationSettings(tcin: records.target.tcin, location: location)
            if let old {
                old.key = key
                old.landmarkID = clean; old.activateAfterMeters = start; old.deactivateAfterMeters = end
                old.side = side; old.isInStore = isInStore; old.enabled = true
            } else {
                modelContext.insert(ProductActivationSettings(key: key, tcin: records.target.tcin,
                    location: location, landmarkID: clean, start: start, end: end, side: side, isInStore: isInStore))
            }
            try modelContext.save()
        } catch { modelContext.rollback(); throw error }
    }

    private func activationSettings(tcin: String, location: CatalogLocation) throws -> ProductActivationSettings? {
        // Match saved fields so rules written with the former key format still load.
        let floor = location.floor, block = location.block, aisle = location.aisle
        return try modelContext.fetch(FetchDescriptor<ProductActivationSettings>(predicate: #Predicate {
            $0.tcin == tcin && $0.floor == floor && $0.block == block && $0.aisle == aisle
        })).first
    }

    private func profileMap() throws -> [String: ProductRecognitionProfile] {
        Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ProductRecognitionProfile>()).map { ($0.tcin, $0) })
    }
    private func record(_ product: Product, profile: ProductRecognitionProfile) -> CatalogProductRecord {
        CatalogProductRecord(id: profile.recognitionID, tcin: product.tcin, title: product.title,
            brand: profile.brand, aliases: profile.aliases,
            locations: Array(Set(product.locations.map { CatalogLocation(floor: $0.floor, block: $0.block, aisle: $0.aisle) })).sorted { $0.id < $1.id })
    }
    private func matches(_ stored: StoreLocation, _ selected: CatalogLocation) -> Bool {
        stored.floor == selected.floor && stored.block == selected.block && stored.aisle == selected.aisle
    }
    private func validateRule(landmark: String, start: Double, end: Double, side: String?) throws {
        guard !landmark.isEmpty, start.isFinite, end.isFinite, start >= 0, end >= start,
              side == nil || side == "left" || side == "right" else { throw CatalogDatabaseError.invalidRule }
    }
    private static func ruleKey(tcin: String, location: CatalogLocation) -> String {
        // Length-prefix each field to avoid separator collisions.
        [tcin, location.floor, location.block, String(location.aisle)].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
