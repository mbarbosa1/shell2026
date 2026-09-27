import Foundation
import Observation
import SwiftData
import UIKit

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
    /// Items still to pick up, by block then aisle so they roughly follow the store.
    /// Items with no location (not in the catalog) come last.
    var itemsToGet: [GroceryItem] {
        items.filter { !$0.isCollected }.sorted { a, b in
            switch (a.block, b.block) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (blockA?, blockB?): return (blockA, a.aisle ?? 0) < (blockB, b.aisle ?? 0)
            }
        }
    }
    /// The newest cart item, highlighted as "Just added".
    var justAddedCartID: UUID? { cart.last?.id }

    /// True while the voice agent is connected and the microphone is unmuted.
    var isListening = false
    /// True once the user has turned listening on and the agent is connected (muted or not).
    var isVoiceConnected = false
    /// True while the first connection is being made, so the listening button can't start a second one.
    var isConnectingVoice = false
    /// True while the ESP32 on the cart is connected over Bluetooth (see `CartBluetooth`).
    var isDeviceConnected = false
    /// True while the cart's distance sensor sees something close in front. The watch buzzes the whole time.
    private(set) var isObstacleAhead = false
    /// The last thing the user said to the voice agent.
    var transcript: String?
    /// What the voice agent last did, e.g. "Oat milk added to your list".
    var confirmation: String?
    /// Why the voice agent couldn't connect (or the list couldn't be saved), shown under the listening header.
    var voiceError: String?
    /// The most recently added item gets an outline.
    var highlightedItemID: UUID?
    /// The camera screen is up. Only `startShopping()`, the X (`endShopping()`) and reaching the
    /// cashier change it.
    var isCameraOpen = false
    /// The one ARKit session: the camera feed, the tracking navigation walks by, and the frames
    /// hand guiding reads.
    let camera: CameraService
    /// The walk through the store, while one is going (see `NavigationScreen`).
    private(set) var navigator: RouteNavigator?
    var isNavigating: Bool {
        get { navigator != nil }
        set { if !newValue { stopNavigation() } }
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }
    @ObservationIgnored private var voice: VoiceAgent?
    @ObservationIgnored private let narrator = Narrator()
    @ObservationIgnored private let watch: WatchLink
    @ObservationIgnored private let cartDevice: CartBluetooth
    @ObservationIgnored private var obstacleDetector = ObstacleDetector()
    /// Finds the product on the shelf with the arm and guides the user's hand to it, using the
    /// camera's ARKit frames.
    @ObservationIgnored let pickup: PickupGuide

    init(container: ModelContainer) {
        self.container = container
        ProductImporter.importIfChanged(into: container.mainContext)
        let camera = CameraService()
        let cartDevice = CartBluetooth()
        let watch = WatchLink()
        self.camera = camera
        self.cartDevice = cartDevice
        self.watch = watch
        pickup = PickupGuide(arm: ArmController(cart: cartDevice), watch: watch, session: camera.session)
        currentList = Self.openList(in: container.mainContext)
        highlightedItemID = currentList.sortedItems.last?.id
        refresh()
        voice = VoiceAgent(model: self)
        connectCartDevice()
    }

    func toggleCollected(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        setCollected(item, !item.isCollected, source: .app)
    }

    func isOnList(_ item: some ItemDescribing) -> Bool {
        items.contains { $0.name == item.name && $0.brand == item.brand }
    }

    func addUsualsToList(source: ListEvent.Source = .app) {
        var added: [GroceryItem] = []
        for usual in usuals where !isOnList(usual) {
            let item = GroceryItem(
                name: usual.name, brand: usual.brand, label: usual.label, size: usual.size,
                aisle: usual.aisle, block: usual.block
            )
            // Keep the product link, so the usual stays matched to the same catalog product.
            item.tcin = usual.tcin
            item.price = usual.price
            item.floor = usual.floor
            insert(item, source: source)
            if item.tcin == nil { matchToCatalog(item) }
            added.append(item)
        }
        save()
        guard let last = added.last else { return }
        highlightedItemID = last.id
        confirmation = added.count == 1 ? "\(last.name) added to your list" : "\(added.count) usuals added to your list"
    }

    // MARK: Navigation

    /// What's left on the list, for the route planner.
    var routeItems: [RoutePlanner.Item] {
        items.filter { !$0.isCollected }.map { RoutePlanner.Item(name: $0.name, location: $0.location) }
    }

    /// "Start shopping", from the button or the voice agent. Links anything not matched to the
    /// catalog yet, so the route knows where it is, and returns the items the store doesn't carry.
    /// The user is always at the store's starting point, so tracking starts (and is measured from)
    /// here. The camera stays on until the route reaches the cashier or the user taps the X.
    @discardableResult
    func startShopping() -> [GroceryItem] {
        let notFound = matchUnlinkedItems()
        guard !isCameraOpen else { return notFound }
        isCameraOpen = true
        Task {
            let tracking = await camera.start()
            // The X was tapped while the camera permission prompt was up.
            guard isCameraOpen else {
                camera.stop()
                return
            }
            // No ARKit (simulator) or no camera permission: walk the route by hand instead.
            startNavigation(simulated: !tracking)
        }
        return notFound
    }

    /// The X on the camera screen: the user leaves before reaching the cashier.
    func endShopping() {
        stopNavigation()
        closeCamera()
    }

    /// The route reached the cashier. Doesn't stop the narrator, so the cashier message is heard.
    private func finishShopping() {
        UIApplication.shared.isIdleTimerDisabled = false
        closeCamera()
    }

    private func closeCamera() {
        pickup.stop()
        camera.stop()
        isCameraOpen = false
    }

    /// Starts guiding the user through the store. Simulated when asked, or when the phone can't
    /// run ARKit world tracking (e.g. the simulator).
    func startNavigation(simulated: Bool = false) {
        navigator?.stop()
        let navigator = RouteNavigator(
            map: .target,
            simulated: simulated || !PositionTracker.isSupported,
            session: camera.session,
            remainingItems: { [weak self] in self?.routeItems ?? [] },
            announce: { [weak self] text, haptic in self?.announce(text, haptic: haptic) },
            onFinish: { [weak self] in self?.finishShopping() }
        )
        self.navigator = navigator
        // The phone sits on the cart the whole walk: don't let it lock.
        UIApplication.shared.isIdleTimerDisabled = true
        navigator.start()
        // Started from the route screen rather than "Start shopping": ARKit isn't running yet.
        // Does nothing when it already is, so tracking isn't reset.
        if !navigator.isSimulated {
            Task {
                _ = await camera.start()
                if !isNavigating && !isCameraOpen { camera.stop() }
            }
        }
    }

    func stopNavigation() {
        navigator?.stop()
        navigator = nil
        narrator.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        // The camera stays on while shopping; it only goes off at the cashier or with the X.
        if !isCameraOpen { camera.stop() }
    }

    /// Plays the cue on the watch and says it: through VoiceOver when it's on, so the two
    /// don't talk over each other, and the narrator otherwise.
    private func announce(_ text: String, haptic: WatchHaptic?) {
        watch.send(haptic, text: text)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            narrator.speak(text)
        }
    }

    // MARK: Voice agent

    func setListening(_ isListening: Bool) async {
        // VoiceOver already reads the screen aloud. The agent talking too would make both unusable.
        if isListening && UIAccessibility.isVoiceOverRunning { return }
        await voice?.setListening(isListening)
    }

    /// Called when VoiceOver is turned on or off. Turning it on hangs up the agent;
    /// turning it off leaves the agent off until the user starts it again.
    func voiceOverChanged() async {
        if UIAccessibility.isVoiceOverRunning {
            await voice?.stop()
        }
    }

    //as the voice agent hears items to add, we need to add them to the databse
    //along with adding items to the database we need to update status
    func addItem(_ item: GroceryItem, source: ListEvent.Source = .app) {
        insert(item, source: source)
        matchToCatalog(item)
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
        navigator?.itemsChanged()
        confirmation = "\(removedName) removed from your list"
        return true
    }

    enum CheckOffResult { case checkedOff, alreadyInCart, notOnList }

    /// Puts an item in the cart. An item that's already there is left alone, so saying it twice
    /// doesn't move it back to "Just added" or log a second check-off.
    func checkOffItem(named name: String, source: ListEvent.Source = .app) -> CheckOffResult {
        guard let item = item(named: name) else { return .notOnList }
        guard !item.isCollected else {
            confirmation = "\(item.name) is already in your cart"
            return .alreadyInCart
        }
        setCollected(item, true, source: source)
        confirmation = "\(item.name) checked off"
        return .checkedOff
    }

    /// Changes the fields that are given and leaves the rest. Returns false if no item has that name.
    func updateItem(
        named name: String, quantity: Int? = nil, brand: String? = nil, label: String? = nil, size: String? = nil,
        aisle: Int? = nil, block: String? = nil, isCollected: Bool? = nil, source: ListEvent.Source = .app
    ) -> Bool {
        guard let item = item(named: name) else { return false }
        if quantity != nil || brand != nil || label != nil || size != nil || aisle != nil || block != nil {
            if brand != nil || label != nil || size != nil {
                unlink(item)
            }
            if let quantity { item.quantity = quantity }
            if let brand { item.brand = brand }
            if let label { item.label = label }
            if let size { item.size = size }
            if let aisle { item.aisle = aisle }
            if let block { item.block = block.uppercased() }
            if item.tcin == nil { matchToCatalog(item) }
            log(.updated, item.name, source: source)
            save()
        }
        if let isCollected, isCollected != item.isCollected {
            setCollected(item, isCollected, source: source)
        }
        highlightedItemID = item.id
        confirmation = "\(item.name) updated"
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

    // MARK: Matching to the product catalog

    /// The catalog only changes at launch, so it's fetched once.
    @ObservationIgnored private var cachedProducts: [Product]?
    private var catalogProducts: [Product] {
        if let cachedProducts { return cachedProducts }
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        cachedProducts = products
        return products
    }

    /// Links the item to the product we think the user means (see `ProductMatcher`) and copies its
    /// tcin, price and location onto it. Returns false when the store doesn't carry it.
    @discardableResult
    func matchToCatalog(_ item: GroceryItem) -> Bool {
        guard let product = ProductMatcher.bestProduct(
            name: item.name, label: item.label, brand: item.brand, in: catalogProducts
        ) else { return false }
        item.fill(from: product)
        save()
        return true
    }

    /// The catalog product an item is linked to.
    func product(for item: GroceryItem) -> Product? {
        guard let tcin = item.tcin else { return nil }
        return catalogProducts.first { $0.tcin == tcin }
    }

    /// Clears what the item got from its old product, so it can be matched again. Values the
    /// user set themselves (a different brand or aisle than the product's) are kept.
    private func unlink(_ item: GroceryItem) {
        if let old = product(for: item) {
            if item.brand == old.brand { item.brand = nil }
            if item.size == old.size { item.size = nil }
            if let spot = old.primaryLocation, item.aisle == spot.aisle, item.block == spot.block {
                item.aisle = nil
                item.block = nil
                item.floor = nil
            }
        }
        item.tcin = nil
        item.price = nil
    }

    /// Matches every item on the open list that isn't linked yet. Returns the ones the store doesn't carry.
    func matchUnlinkedItems() -> [GroceryItem] {
        var notFound: [GroceryItem] = []
        for item in items where item.tcin == nil {
            if !matchToCatalog(item) { notFound.append(item) }
        }
        return notFound
    }

    func list(number: Int) -> GroceryList? {
        let descriptor = FetchDescriptor<GroceryList>(predicate: #Predicate { $0.number == number })
        return try? context.fetch(descriptor).first
    }

    // MARK: Cart device and watch

    private func connectCartDevice() {
        cartDevice.onConnectionChange = { [weak self] isConnected in
            guard let self else { return }
            isDeviceConnected = isConnected
            // No readings without the cart, so stop the alarm instead of buzzing forever.
            if !isConnected {
                obstacleDetector.reset()
                setObstacleAhead(false)
            }
        }
        cartDevice.onDistance = { [weak self] cm in
            guard let self, obstacleDetector.update(distanceCm: cm) else { return }
            setObstacleAhead(obstacleDetector.isObstacleAhead)
        }
    }

    private func setObstacleAhead(_ isAhead: Bool) {
        guard isAhead != isObstacleAhead else { return }
        isObstacleAhead = isAhead
        // Watch only, no voice: the alarm buzzes until the path is clear.
        watch.send(isAhead ? .obstacleOn : .obstacleOff,
                   text: isAhead ? "Stop. Something is in front of the cart." : "Path clear.")
    }

 // MARK: Onboarding

    /// Saved on the phone, so onboarding only shows on first launch.
    var hasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded") {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }
    /// Which onboarding page is showing. The buttons and the voice agent both change it.
    var onboardingPage = 0

    /// Moves to an onboarding page and returns what the voice agent should say.
    func showOnboardingPage(_ index: Int) -> (message: String, isError: Bool) {
        guard !hasOnboarded else { return ("Onboarding is already finished.", true) }
        let pages = OnboardingPage.all
        guard pages.indices.contains(index) else {
            return (index < 0
                ? "This is already the first page."
                : "This is the last page. The user can say “get started” to finish.", true)
        }
        onboardingPage = index
        return ("Now on page \(index + 1) of \(pages.count). Read this to the user: \(pages[index].spoken)", false)
    }

    func finishOnboarding() {
        hasOnboarded = true
    }

    /// Demo helper: shows onboarding again from the first page.
    func restartOnboarding() {
        onboardingPage = 0
        hasOnboarded = false
    }

     /// Checks the "Replay onboarding" switch in the iPhone Settings app.
    func checkReplayOnboardingSetting() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "replayOnboarding") else { return }
        defaults.set(false, forKey: "replayOnboarding") // turns the switch back off
        restartOnboarding()
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

    #if DEBUG
    /// Every list and item as saved, read back from the database. Printed after each voice tool call.
    var databaseSnapshot: String {
        let lists = (try? context.fetch(FetchDescriptor<GroceryList>(sortBy: [SortDescriptor(\.number)]))) ?? []
        let rows = lists.map { list in
            let items = list.sortedItems.map { item in
                "   • \(item.name) | quantity \(item.quantity) | label \(item.label ?? "nil") | brand \(item.brand ?? "nil")"
                    + " | aisle \(item.aisle.map(String.init) ?? "nil") | block \(item.block ?? "nil") | in cart \(item.isCollected)"
            }
            let header = "🗄️ List \(list.number) (\(list.isOpen ? "open" : "finished"), \(list.history.count) history events)"
            return ([header] + (items.isEmpty ? ["   (no items)"] : items)).joined(separator: "\n")
        }
        let products = (try? context.fetchCount(FetchDescriptor<Product>())) ?? 0
        return (rows + ["Product catalog: \(products) products"]).joined(separator: "\n")
    }
    #endif
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
        navigator?.itemsChanged()
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
    /// then by how recently they were added. Uses the newest copy's label and size, the newest
    /// known location, and the newest product link, so adding an item without one doesn't forget them.
    private static func rank(_ items: [GroceryItem]) -> [CommonItem] {
        var groups: [String: (newest: GroceryItem, located: GroceryItem?, linked: GroceryItem?, lists: Set<Int>)] = [:]
        for item in items {
            guard let number = item.list?.number else { continue }
            let key = CommonItem.key(name: item.name, brand: item.brand)
            var group = groups[key] ?? (item, nil, nil, [])
            if item.addedAt > group.newest.addedAt { group.newest = item }
            if item.location != nil, item.addedAt > (group.located?.addedAt ?? .distantPast) { group.located = item }
            if item.tcin != nil, item.addedAt > (group.linked?.addedAt ?? .distantPast) { group.linked = item }
            group.lists.insert(number)
            groups[key] = group
        }
        return groups
            .map { key, group in
                CommonItem(
                    id: key, name: group.newest.name, brand: group.newest.brand,
                    label: group.newest.label, size: group.newest.size,
                    aisle: group.located?.aisle, block: group.located?.block, floor: group.located?.floor,
                    tcin: group.linked?.tcin, price: group.linked?.price,
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
                GroceryItem(name: "Bananas", label: "Fresh produce", quantity: 3, aisle: 1, block: "A", addedAt: date),
                GroceryItem(name: "Rolled oats", brand: "Quaker", label: "Old Fashioned", size: "18 oz", aisle: 26, block: "F", addedAt: date.addingTimeInterval(1)),
                GroceryItem(name: "Oat milk", brand: "Oatly", label: "Original", size: "64 fl oz", aisle: 44, block: "G", addedAt: date.addingTimeInterval(2)),
            ]
            list.history = list.items.map { ListEvent(kind: .added, itemName: $0.name, source: .voice, date: $0.addedAt) }
        }
        try? context.save()
        return AppModel(container: container)
    }
}
