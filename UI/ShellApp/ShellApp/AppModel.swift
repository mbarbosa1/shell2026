import Foundation
import Observation

/// UI state for the screens. The list starts with sample data from the Figma;
/// the voice agent (`VoiceAgent`) updates it through the methods below.
@MainActor
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
    /// True while the voice agent is connected and the microphone is unmuted.
    var isListening = false
    var isDeviceConnected = true
    /// The last thing the user said to the voice agent.
    var transcript: String?
    /// What the voice agent last did, e.g. "Oat milk added to your list".
    var confirmation: String?
    /// Why the voice agent couldn't connect, shown under the listening header.
    var voiceError: String?
    /// The most recently added item gets an outline.
    var highlightedItemID: GroceryItem.ID?
    var isCameraOpen = false

    @ObservationIgnored private var voice: VoiceAgent?

    init() {
        highlightedItemID = items.last?.id
        justAddedCartID = cart.last?.id
        voice = VoiceAgent(model: self)
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

    // MARK: Voice agent

    func startVoice() async {
        await voice?.start()
    }

    func setListening(_ isListening: Bool) async {
        await voice?.setListening(isListening)
    }

    func addItem(_ item: GroceryItem) {
        items.append(item)
        highlightedItemID = item.id
        confirmation = "\(item.name) added to your list"
    }

    /// Returns false if no item has that name.
    func removeItem(named name: String) -> Bool {
        guard let index = firstIndex(named: name) else { return false }
        let removed = items.remove(at: index)
        confirmation = "\(removed.name) removed from your list"
        return true
    }

    /// Returns false if no item has that name.
    func checkOffItem(named name: String) -> Bool {
        guard let index = firstIndex(named: name) else { return false }
        items[index].isCollected = true
        confirmation = "\(items[index].name) checked off"
        return true
    }

    /// The list as text for the agent: "Bananas (3 bananas · Fresh produce), Oat milk (…, in cart)".
    var listSummary: String {
        guard !items.isEmpty else { return "The list is empty." }
        let entries = items.map { item in
            var parts = [item.detail].filter { !$0.isEmpty }
            if item.isCollected { parts.append("in cart") }
            return parts.isEmpty ? item.name : "\(item.name) (\(parts.joined(separator: ", ")))"
        }
        return "The list: " + entries.joined(separator: ", ") + "."
    }

    private func firstIndex(named name: String) -> Int? {
        items.firstIndex { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}

private extension Date {
    static func sample(month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day)) ?? .now
    }
}
