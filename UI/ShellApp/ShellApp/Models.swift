import Foundation

struct GroceryItem: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var brand: String?
    var label: String?
    var size: String?
    var quantity = 1
    var isCollected = false

    /// "Oatly · Original · 64 fl oz" or "3 bananas · Fresh produce".
    var detail: String {
        var parts: [String] = []
        if quantity > 1 { parts.append("\(quantity) \(name.lowercased())") }
        parts += [brand, label, size].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

struct Trip: Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var store: String
    var items: [GroceryItem]

    /// "Publix · 8 items"
    var summary: String { "\(store) · \(items.count) items" }
}

/// Something already placed in the cart, shown on the camera screen.
struct CartItem: Identifiable, Hashable {
    var id = UUID()
    /// "Quaker · Old Fashioned oats"
    var title: String
    /// "1 bunch", "1"
    var quantity: String
}
