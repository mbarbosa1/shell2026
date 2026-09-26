import Foundation
import SwiftData

/// The on-device grocery database (SwiftData).
enum GroceryDatabase {
    static let schema = Schema([GroceryList.self, GroceryItem.self, ListEvent.self])

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }
}

/// Anything shown as a grocery row: list items and usuals.
protocol ItemDescribing {
    var name: String { get }
    var brand: String? { get }
    var label: String? { get }
    var size: String? { get }
    var quantity: Int { get }
}

extension ItemDescribing {
    /// "Oatly · Original · 64 fl oz" or "3 bananas · Fresh produce".
    var detail: String {
        var parts: [String] = []
        if quantity > 1 { parts.append("\(quantity) \(name.lowercased())") }
        parts += [brand, label, size].compactMap { $0 }
        return parts.joined(separator: " · ")
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
    var isCollected = false
    var addedAt: Date
    /// When the item went in the cart.
    var collectedAt: Date?
    var list: GroceryList?

    init(name: String, brand: String? = nil, label: String? = nil, size: String? = nil, quantity: Int = 1, addedAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.brand = brand
        self.label = label
        self.size = size
        self.quantity = quantity
        self.addedAt = addedAt
    }
}

/// One entry in a list's history, e.g. "Added Oat milk" by voice.
@Model
final class ListEvent {
    enum Kind: String {
        //updating th products status in the database
        case added, removed, checkedOff, unchecked, finished
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
    var timesListed: Int
    var lastAdded: Date

    static func key(name: String, brand: String?) -> String {
        [name, brand ?? ""].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "|")
    }
}
