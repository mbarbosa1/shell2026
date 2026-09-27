import Foundation
import SwiftData

/// The on-device database (SwiftData). One container, two files:
/// - `default.store`: the user's grocery lists. Never replaced.
/// - `catalog.store`: the product catalog (Target products with aisle and block) from the bundled
///   `Scripts/output/products.json`. `ProductImporter.importIfChanged` rebuilds it when that file changes,
///   without touching the lists.
enum GroceryDatabase {
    static let listSchema = Schema([GroceryList.self, GroceryItem.self, ListEvent.self])
    static let catalogSchema = Schema([Product.self, StoreLocation.self])
    static let schema = Schema([
        GroceryList.self, GroceryItem.self, ListEvent.self, Product.self, StoreLocation.self,
    ])

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let lists: ModelConfiguration
        let catalog: ModelConfiguration
        if inMemory {
            lists = ModelConfiguration("Lists", schema: listSchema, isStoredInMemoryOnly: true)
            catalog = ModelConfiguration("Catalog", schema: catalogSchema, isStoredInMemoryOnly: true)
        } else {
            // The lists keep the file they've always used, so existing lists carry over.
            lists = ModelConfiguration(schema: listSchema, url: .applicationSupportDirectory.appending(path: "default.store"))
            catalog = ModelConfiguration(schema: catalogSchema, url: .applicationSupportDirectory.appending(path: "catalog.store"))
        }
        return try ModelContainer(for: schema, configurations: lists, catalog)
    }
}

/// Anything shown as a grocery row: list items and usuals.
protocol ItemDescribing {
    var name: String { get }
    var brand: String? { get }
    var label: String? { get }
    var size: String? { get }
    var quantity: Int { get }
    var aisle: Int? { get }
    var block: String? { get }
}

extension ItemDescribing {
    /// "Oatly · Original · 64 fl oz" or "3 bananas · Fresh produce".
    var detail: String {
        var parts: [String] = []
        if quantity > 1 { parts.append("\(quantity) \(name.lowercased())") }
        parts += [brand, label, size, location.map { "Aisle \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    /// Where it is in the store, e.g. "G44" (block G, aisle 44). Nil until both are known.
    var location: String? {
        guard let block, let aisle else { return nil }
        return "\(block)\(aisle)"
    }
}

/// One numbered grocery list. The open list (`completedAt == nil`) is the one the Shop screen
/// and the voice agent edit. Finishing it moves it to History and starts the next number.
@Model
final class GroceryList {
    @Attribute(.unique) var number: Int
    /// When the list was started.
    var date: Date
    /// When the trip was finished. Nil while the list is open.
    var completedAt: Date?
    var store: String?
    @Relationship(deleteRule: .cascade, inverse: \GroceryItem.list)
    var items: [GroceryItem] = []
    /// Everything that happened to this list, from the app or by voice.
    @Relationship(deleteRule: .cascade, inverse: \ListEvent.list)
    var history: [ListEvent] = []

    init(number: Int, date: Date = .now) {
        self.number = number
        self.date = date
    }

    var isOpen: Bool { completedAt == nil }

    // SwiftData doesn't keep relationship order, so sort by time.
    var sortedItems: [GroceryItem] { items.sorted { $0.addedAt < $1.addedAt } }
    var sortedHistory: [ListEvent] { history.sorted { $0.date < $1.date } }

    /// "List 3 · Publix · 8 items"
    var summary: String {
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return ["List \(number)", store, count].compactMap { $0 }.joined(separator: " · ")
    }
}

@Model
final class GroceryItem: ItemDescribing {
    @Attribute(.unique) var id: UUID
    var name: String
    var brand: String?
    var label: String?
    var size: String?
    var quantity: Int
    /// Store location, matching the product database's `StoreLocation`: aisle 44 in block "G".
    var aisle: Int?
    var block: String?
    /// Store floor, e.g. "01". Only matters in multi-floor stores.
    var floor: String?
    /// Target's ID for the matched catalog product (`Product.tcin`), so its details can be looked up again.
    var tcin: String?
    /// Price when the item was matched. Kept on the item so past trips show what it cost that day.
    var price: Double?
    var isCollected = false
    var addedAt: Date
    /// When the item went in the cart.
    var collectedAt: Date?
    var list: GroceryList?

    init(
        name: String, brand: String? = nil, label: String? = nil, size: String? = nil, quantity: Int = 1,
        aisle: Int? = nil, block: String? = nil, addedAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.brand = brand
        self.label = label
        self.size = size
        self.quantity = quantity
        self.aisle = aisle
        self.block = block
        self.addedAt = addedAt
    }

    /// Copies a catalog product's details onto this item: its link, price, and store location.
    /// Brand, size and location are only filled when empty, so what the user said is never overwritten.
    func fill(from product: Product) {
        tcin = product.tcin
        price = product.currentPrice
        if brand == nil { brand = product.brand }
        if size == nil { size = product.size }
        if let spot = product.primaryLocation, aisle == nil || block == nil {
            aisle = spot.aisle
            block = spot.block
            floor = spot.floor
        }
    }
}

/// One entry in a list's history, e.g. "Added Oat milk" by voice.
@Model
final class ListEvent {
    enum Kind: String {
        //updating th products status in the database
        case added, updated, removed, checkedOff, unchecked, finished
    }

    enum Source: String {
        case voice, app
    }

    var date: Date
    // Stored as raw strings so SwiftData doesn't need Codable enums.
    var kindRaw: String
    var sourceRaw: String
    var itemName: String?
    var list: GroceryList?

    init(kind: Kind, itemName: String?, source: Source, date: Date = .now) {
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.itemName = itemName
        self.date = date
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .added }
    var source: Source { Source(rawValue: sourceRaw) ?? .app }

    /// "Added Oat milk", "Finished the trip"
    var text: String {
        let item = itemName ?? "an item"
        switch kind {
        case .added: return "Added \(item)"
        case .updated: return "Updated \(item)"
        case .removed: return "Removed \(item)"
        case .checkedOff: return "Checked off \(item)"
        case .unchecked: return "Unchecked \(item)"
        case .finished: return "Finished the trip"
        }
    }
}

/// An item ranked by how many lists it has been on. Computed from the database, not stored.
struct CommonItem: ItemDescribing, Identifiable, Hashable {
    /// Lowercased name and brand, so "oat milk" and "Oat milk" count together.
    var id: String
    var name: String
    var brand: String?
    var label: String?
    var size: String?
    var quantity: Int { 1 }
    var aisle: Int?
    var block: String?
    var timesListed: Int
    var lastAdded: Date

    static func key(name: String, brand: String?) -> String {
        [name, brand ?? ""].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "|")
    }
}
