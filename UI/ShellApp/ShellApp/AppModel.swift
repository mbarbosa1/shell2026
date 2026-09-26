import Foundation
import Observation
import SwiftData

/// UI state for the screens, backed by the grocery database (`GroceryDatabase`).
/// The screens and the voice agent (`VoiceAgent`) change the list through the methods below,
/// and each change is saved and logged in the list's history.
@MainActor
@Observable
final class AppModel {
    /// The open list the Shop screen and the voice agent edit.
    private(set) var currentList: GroceryList
    /// Finished lists, newest first.
    private(set) var trips: [GroceryList] = []
    /// Items ranked by how many lists they've been on. Recomputed after every change.
    private(set) var mostCommonItems: [CommonItem] = []

    var items: [GroceryItem] { currentList.sortedItems }
    /// Common items that have been on at least two lists.
    var usuals: [CommonItem] { Array(mostCommonItems.filter { $0.timesListed >= 2 }.prefix(5)) }
    /// What's been placed in the cart, in the order it went in, shown on the camera screen.
    var cart: [GroceryItem] {
        items.filter(\.isCollected).sorted { ($0.collectedAt ?? .distantPast) < ($1.collectedAt ?? .distantPast) }
    }
    /// The newest cart item, highlighted as "Just added".
    var justAddedCartID: GroceryItem.ID? { cart.last?.id }

    /// True while the voice agent is connected and the microphone is unmuted.
    var isListening = false
    var isDeviceConnected = true
    /// The last thing the user said to the voice agent.
    var transcript: String?
    /// What the voice agent last did, e.g. "Oat milk added to your list".
    var confirmation: String?
    /// Why the voice agent couldn't connect (or the list couldn't be saved), shown under the listening header.
    var voiceError: String?
    /// The most recently added item gets an outline.
    var highlightedItemID: GroceryItem.ID?
    var isCameraOpen = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }
    @ObservationIgnored private var voice: VoiceAgent?

    init(container: ModelContainer) {
        self.container = container
        currentList = Self.openList(in: container.mainContext)
        highlightedItemID = currentList.sortedItems.last?.id
        refresh()
        voice = VoiceAgent(model: self)
    }

    func toggleCollected(_ id: GroceryItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        setCollected(item, !item.isCollected, source: .app)
    }

    func isOnList(_ item: some ItemDescribing) -> Bool {
        items.contains { $0.name == item.name && $0.brand == item.brand }
    }

    func addUsualsToList(source: ListEvent.Source = .app) {
        for usual in usuals where !isOnList(usual) {
            insert(GroceryItem(name: usual.name, brand: usual.brand, label: usual.label, size: usual.size), source: source)
        }
        save()
    }

    // MARK: Voice agent

    func startVoice() async {
        await voice?.start()
    }

    func setListening(_ isListening: Bool) async {
        await voice?.setListening(isListening)
    }
    //as the voice agent hears items to add, we need to add them to the databse
    //along with adding items to the database we need to update status
    func addItem(_ item: GroceryItem, source: ListEvent.Source = .app) {
        insert(item, source: source)
        save()
        highlightedItemID = item.id
        confirmation = "\(item.name) added to your list"
    }

    /// Returns false if no item has that name.
    func removeItem(named name: String, source: ListEvent.Source = .app) -> Bool {
        guard let item = item(named: name) else { return false }
        let removedName = item.name
        currentList.items.removeAll { $0.id == item.id }
        context.delete(item)
        log(.removed, removedName, source: source)
        save()
        confirmation = "\(removedName) removed from your list"
        return true
    }

    /// Returns false if no item has that name.
    func checkOffItem(named name: String, source: ListEvent.Source = .app) -> Bool {
        guard let item = item(named: name) else { return false }
        setCollected(item, true, source: source)
        confirmation = "\(item.name) checked off"
        return true
    }

    /// Saves the open list to History and starts the next number. Returns the finished list.
    @discardableResult
    func finishList(at store: String? = nil, source: ListEvent.Source = .app) -> GroceryList {
        let finished = currentList
        finished.completedAt = .now
        if let store, !store.isEmpty { finished.store = store }
        log(.finished, nil, source: source)

        let next = GroceryList(number: finished.number + 1)
        context.insert(next)
        currentList = next
        highlightedItemID = nil
        save()
        confirmation = "List \(finished.number) saved to History"
        return finished
    }

    func list(number: Int) -> GroceryList? {
        let descriptor = FetchDescriptor<GroceryList>(predicate: #Predicate { $0.number == number })
        return try? context.fetch(descriptor).first
    }

    // MARK: Text for the agent

    /// The current list as text: "List 3 (open, started September 26): Bananas (3 bananas · Fresh produce), …".
    var listSummary: String { summary(of: currentList) }

    func summary(of list: GroceryList) -> String {
        var header = "List \(list.number)"
        var facts = [list.isOpen ? "open" : "finished"]
        if let store = list.store { facts.append("at \(store)") }
        facts.append("started \(list.date.formatted(.dateTime.month(.wide).day()))")
        header += " (\(facts.joined(separator: ", ")))"

        guard !list.items.isEmpty else { return "\(header) is empty." }
        let entries = list.sortedItems.map { item in
            var parts = [item.detail].filter { !$0.isEmpty }
            if item.isCollected { parts.append("in cart") }
            return parts.isEmpty ? item.name : "\(item.name) (\(parts.joined(separator: ", ")))"
        }
        return "\(header): " + entries.joined(separator: ", ") + "."
    }

    /// "List 3 history: 5:02 PM Added Oat milk (voice), …"
    func historySummary(of list: GroceryList) -> String {
        guard !list.history.isEmpty else { return "List \(list.number) has no history yet." }
        let entries = list.sortedHistory.map { event in
            "\(event.date.formatted(date: .omitted, time: .shortened)) \(event.text) (\(event.source.rawValue))"
        }
        return "List \(list.number) history: " + entries.joined(separator: ", ") + "."
    }

    /// "Most common: Oat milk (Oatly, on 4 lists), …"
    var mostCommonSummary: String {
        guard !mostCommonItems.isEmpty else { return "There are no items yet." }
        let entries = mostCommonItems.prefix(10).map { item in
            let brand = item.brand.map { "\($0), " } ?? ""
            return "\(item.name) (\(brand)on \(item.timesListed == 1 ? "1 list" : "\(item.timesListed) lists"))"
        }
        return "Most common: " + entries.joined(separator: ", ") + "."
    }

    // MARK: Database

    //as soon as you finish the user session it doesnt import into the database
    

    private func insert(_ item: GroceryItem, source: ListEvent.Source) {
        currentList.items.append(item)
        log(.added, item.name, source: source)
    }
    

    private func setCollected(_ item: GroceryItem, _ isCollected: Bool, source: ListEvent.Source) {
        item.isCollected = isCollected
        item.collectedAt = isCollected ? .now : nil
        log(isCollected ? .checkedOff : .unchecked, item.name, source: source)
        save()
    }

    private func log(_ kind: ListEvent.Kind, _ itemName: String?, source: ListEvent.Source) {
        currentList.history.append(ListEvent(kind: kind, itemName: itemName, source: source))
    }

    private func save() {
        do {
            try context.save()
        } catch {
            voiceError = "Couldn't save the list: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Reloads the values computed from the whole database.
    private func refresh() {
        let finished = FetchDescriptor<GroceryList>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.number, order: .reverse)]
        )
        trips = (try? context.fetch(finished)) ?? []
        mostCommonItems = Self.rank((try? context.fetch(FetchDescriptor<GroceryItem>())) ?? [])
    }

    private func item(named name: String) -> GroceryItem? {
        items.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// The newest open list, or a new one numbered after the last list.
    private static func openList(in context: ModelContext) -> GroceryList {
        var open = FetchDescriptor<GroceryList>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [SortDescriptor(\.number, order: .reverse)]
        )
        open.fetchLimit = 1
        if let list = try? context.fetch(open).first { return list }

        var last = FetchDescriptor<GroceryList>(sortBy: [SortDescriptor(\.number, order: .reverse)])
        last.fetchLimit = 1
        let number = ((try? context.fetch(last).first?.number) ?? 0) + 1
        let list = GroceryList(number: number)
        context.insert(list)
        try? context.save()
        return list
    }

    /// Groups items by name and brand and ranks them by how many lists they've been on,
    /// then by how recently they were added. Uses the newest copy's label and size.
    private static func rank(_ items: [GroceryItem]) -> [CommonItem] {
        var groups: [String: (newest: GroceryItem, lists: Set<Int>)] = [:]
        for item in items {
            guard let number = item.list?.number else { continue }
            let key = CommonItem.key(name: item.name, brand: item.brand)
            var group = groups[key] ?? (item, [])
            if item.addedAt > group.newest.addedAt { group.newest = item }
            group.lists.insert(number)
            groups[key] = group
        }
        return groups
            .map { key, group in
                CommonItem(
                    id: key, name: group.newest.name, brand: group.newest.brand,
                    label: group.newest.label, size: group.newest.size,
                    timesListed: group.lists.count, lastAdded: group.newest.addedAt
                )
            }
            .sorted { ($0.timesListed, $0.lastAdded) > ($1.timesListed, $1.lastAdded) }
    }
}

// MARK: Previews

extension AppModel {
    /// An in-memory database with the Figma sample data.
    static var preview: AppModel {
        let container = try! GroceryDatabase.container(inMemory: true)
        let context = container.mainContext
        let sample: [(month: Int, day: Int, store: String?)] = [(9, 19, "Trader Joe’s"), (9, 23, "Publix"), (9, 26, nil)]

        for (index, trip) in sample.enumerated() {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: trip.month, day: trip.day)) ?? .now
            let list = GroceryList(number: index + 1, date: date)
            list.store = trip.store
            if trip.store != nil { list.completedAt = date }
            context.insert(list)
            list.items = [
                GroceryItem(name: "Bananas", label: "Fresh produce", quantity: 3, addedAt: date),
                GroceryItem(name: "Rolled oats", brand: "Quaker", label: "Old Fashioned", size: "18 oz", addedAt: date.addingTimeInterval(1)),
                GroceryItem(name: "Oat milk", brand: "Oatly", label: "Original", size: "64 fl oz", addedAt: date.addingTimeInterval(2)),
            ]
            list.history = list.items.map { ListEvent(kind: .added, itemName: $0.name, source: .voice, date: $0.addedAt) }
        }
        try? context.save()
        return AppModel(container: container)
    }
}
