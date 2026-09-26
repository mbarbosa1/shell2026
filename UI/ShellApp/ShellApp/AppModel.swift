import Foundation
import Observation

/// UI state for the screens, filled with sample data from the Figma.
/// Later, the voice agent can update these properties.
@Observable
final class AppModel {
    var items: [GroceryItem] = [
        GroceryItem(name: "Bananas", label: "Fresh produce", quantity: 3),
        GroceryItem(name: "Rolled oats", brand: "Quaker", label: "Old Fashioned", size: "18 oz"),
        GroceryItem(name: "Oat milk", brand: "Oatly", label: "Original", size: "64 fl oz"),
    ]
    var usuals: [GroceryItem] = [
        GroceryItem(name: "Oat milk", brand: "Oatly", label: "Original", size: "64 fl oz"),
        GroceryItem(name: "Rolled oats", brand: "Quaker", label: "Old Fashioned", size: "18 oz"),
    ]
    var trips: [Trip] = [
        Trip(date: .sample(month: 9, day: 23), store: "Publix", items: Array(repeating: GroceryItem(name: "Item"), count: 8)),
        Trip(date: .sample(month: 9, day: 19), store: "Trader Joe’s", items: Array(repeating: GroceryItem(name: "Item"), count: 6)),
    ]
    /// What's been placed in the cart, shown on the camera screen.
    var cart: [CartItem] = [
        CartItem(title: "Bananas", quantity: "1 bunch"),
        CartItem(title: "Quaker · Old Fashioned oats", quantity: "1"),
        CartItem(title: "Oatly · Original", quantity: "1"),
    ]
    /// The newest cart item, highlighted as "Just added".
    var justAddedCartID: CartItem.ID?
    var isListening = true
    var isDeviceConnected = true
    var transcript: String? = "Add bananas and my usual oat milk."
    var confirmation: String? = "Oat milk added to your list"
    /// The most recently added item gets an outline.
    var highlightedItemID: GroceryItem.ID?
    var isCameraOpen = false

    init() {
        highlightedItemID = items.last?.id
        justAddedCartID = cart.last?.id
    }

    func toggleCollected(_ id: GroceryItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isCollected.toggle()
    }

    func isOnList(_ item: GroceryItem) -> Bool {
        items.contains { $0.name == item.name && $0.brand == item.brand }
    }

    func addUsualsToList() {
        items += usuals.filter { !isOnList($0) }
    }
}

private extension Date {
    static func sample(month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day)) ?? .now
    }
}
