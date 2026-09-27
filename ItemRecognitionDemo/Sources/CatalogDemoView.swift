import CatalogIntegration
import ItemRecognition
import ProductDatabase
import SwiftUI

/// A development harness. Data access lives in ProductDatabase, not this screen
/// or ShellApp. No app UI is the canonical owner of catalog information.
struct CatalogDemoView: View {
    @StateObject private var model = CatalogDemoModel()
    @State private var scan: DemoScanConfiguration?
    @AppStorage(DemoCloudAssist.enabledKey) private var cloudEnabled = false
    @AppStorage(DemoCloudAssist.endpointKey) private var cloudEndpoint = ""
    @AppStorage(DemoCloudAssist.tokenKey) private var cloudToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Camera only (no database)") { model.startCameraOnly(); scan = .ocrOnly }
                    Text(model.status).font(.caption)
                    Button("Reload bundled catalog") { Task { await model.load() } }
                }
                Section("Buy list") {
                    TextField("Filter catalog", text: $model.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ForEach(model.suggestions) { product in
                        Button {
                            model.addToList(product)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(product.title)
                                Text(product.itemType ?? "No type").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(model.list) { item in
                        HStack {
                            Text(item.collected ? "✓" : (item.id == model.currentID ? "→" : "•"))
                            VStack(alignment: .leading) {
                                Text(item.product.title)
                                Text(item.product.itemType ?? "No type").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Scan list") {
                        Task { scan = await model.scanCurrent() }
                    }
                    .disabled(model.list.allSatisfy(\.collected))
                    if model.listFinished {
                        Text("List done.")
                    }
                }
                Section("Database test — store 1074") {
                    Picker("Product", selection: $model.selectedID) {
                        Text("Select a product").tag(UUID?.none)
                        ForEach(model.products) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Picker("Location", selection: $model.locationID) {
                        Text("Select a location").tag("")
                        ForEach(model.selectedProduct?.locations ?? []) { Text($0.label).tag($0.id) }
                    }
                    Text("Select a location explicitly. Rules are not inferred from an aisle.").font(.caption)
                }
                Section("Saved activation rule") {
                    TextField("Trigger landmark ID", text: $model.landmark).textInputAutocapitalization(.never)
                    TextField("Activate after metres", text: $model.start).keyboardType(.decimalPad)
                    TextField("Deactivate after metres", text: $model.end).keyboardType(.decimalPad)
                    Picker("Shelf side", selection: $model.side) {
                        Text("Unknown").tag(""); Text("Left").tag("left"); Text("Right").tag("right")
                    }
                    Toggle("Carried at this store", isOn: $model.carried)
                    Text("Membership is separate from sold-out status. Enter surveyed values or explicit demo values.").font(.caption)
                    Button("Save rule") { Task { await model.saveRule() } }.disabled(model.location == nil)
                    Button("Scan selected product") {
                        Task { scan = await model.configuration() }
                    }.disabled(model.location == nil)
                }
                Section("Cloud assist for produce (optional)") {
                    Toggle("Ask cloud when on-device evidence is weak", isOn: $cloudEnabled)
                    TextField("http://<mac-name>.local:8787/v1/produce-label", text: $cloudEndpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Proxy token (not the Gemini key)", text: $cloudToken)
                    Text("Sends one downscaled crop per weak produce frame to your proxy. Packaged items use on-device OCR only. Applies to new scans.")
                        .font(.caption)
                }
            }
            .navigationTitle("Extraction demo")
            .task { await model.load() }
            .onChange(of: model.selectedID) { _, _ in model.locationID = ""; model.clearRule() }
            .onChange(of: model.locationID) { _, _ in Task { await model.loadRule() } }
            .fullScreenCover(item: $scan) { config in
                CameraDemoView(configuration: config, onAccepted: {
                    guard model.scanningList else { return }
                    Task {
                        let next = await model.acceptCurrentScan()
                        scan = nil
                        guard let next else { return }
                        try? await Task.sleep(for: .milliseconds(250))
                        scan = next
                    }
                })
                .id(config.id)
            }
        }
    }
}

@MainActor
final class CatalogDemoModel: ObservableObject {
    @Published private(set) var products: [CatalogProductRecord] = []
    @Published private(set) var status = "Loading catalog…"
    @Published var selectedID: UUID?
    @Published var locationID = ""
    @Published var landmark = ""
    @Published var start = ""
    @Published var end = ""
    @Published var side = ""
    @Published var carried = true
    @Published var query = ""
    @Published private(set) var list: [DemoBuyItem] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var listFinished = false
    @Published private(set) var scanningList = false
    private var database: ProductDatabaseStore?
    private var catalogIndex = ShelfWordIndex.empty
    var selectedProduct: CatalogProductRecord? { products.first { $0.id == selectedID } }
    var location: CatalogLocation? { selectedProduct?.locations.first { $0.id == locationID } }
    var suggestions: [CatalogProductRecord] {
        let ids = catalogIndex.itemIDs(matching: query)
        return Array(products.filter { ids.contains($0.id) }.prefix(8))
    }

    func load() async {
        do {
            let db: ProductDatabaseStore
            if let database { db = database } else { db = try ProductDatabaseStore(); database = db }
            guard let url = Bundle.main.url(forResource: "products", withExtension: "json") else {
                status = "Missing bundled products.json."; return
            }
            let changed = try await db.importProducts(Data(contentsOf: url))
            products = try await db.products()
            catalogIndex = ShelfWordIndex(candidates: snapshots(from: products))
            status = "\(products.count) products · \(changed ? "imported" : "saved catalog loaded")"
            await loadRule()
        } catch { status = error.localizedDescription }
    }
    func clearRule() { landmark = ""; start = ""; end = ""; side = ""; carried = true }
    func loadRule() async {
        clearRule()
        guard let database, let selectedID, let location else { return }
        let selection = location.id
        do {
            let records = try await database.sessionRecords(productID: selectedID, location: location)
            guard self.selectedID == selectedID, locationID == selection else { return }
            if let rule = records.activation {
                landmark = rule.landmarkID; start = String(rule.start); end = String(rule.end)
                side = rule.side ?? ""; carried = rule.isInStore
                status = "Saved rule loaded."
            } else { status = "No saved rule. Scanning stays disabled until one is saved." }
        } catch { status = error.localizedDescription }
    }
    func saveRule() async {
        guard let database, let selectedID, let location, let start = Double(start), let end = Double(end) else {
            status = "Select a product/location and enter both distances."; return
        }
        do {
            try await database.saveActivation(productID: selectedID, location: location,
                landmark: landmark, start: start, end: end, side: side.isEmpty ? nil : side, isInStore: carried)
            status = "Rule saved. Open a new scan to load it."
        } catch { status = error.localizedDescription }
    }
    func configuration() async -> DemoScanConfiguration? {
        scanningList = false
        guard let selectedID, let location, let product = selectedProduct else { return nil }
        return await configuration(for: product, location: location)
    }

    func startCameraOnly() { scanningList = false }

    func addToList(_ product: CatalogProductRecord) {
        guard !list.contains(where: { $0.product.id == product.id }) else { return }
        list.append(DemoBuyItem(product: product))
        listFinished = false
        query = ""
        if currentID == nil { currentID = product.id }
    }

    func scanCurrent() async -> DemoScanConfiguration? {
        guard let item = list.first(where: { !$0.collected }) else { return nil }
        currentID = item.product.id
        scanningList = true
        listFinished = false
        return await listConfiguration(for: item.product)
    }

    func acceptCurrentScan() async -> DemoScanConfiguration? {
        guard let currentID, let index = list.firstIndex(where: { $0.product.id == currentID }) else { return nil }
        list[index].collected = true
        if let next = list.first(where: { !$0.collected }) {
            self.currentID = next.product.id
            return await listConfiguration(for: next.product)
        }
        self.currentID = nil
        listFinished = true
        scanningList = false
        status = "List done."
        return nil
    }

    private func listConfiguration(for product: CatalogProductRecord) async -> DemoScanConfiguration? {
        guard let location = product.locations.first else {
            status = "\(product.title) has no location."; return nil
        }
        return await configuration(for: product, location: location, demoRuleIfMissing: true)
    }

    private func configuration(for product: CatalogProductRecord, location: CatalogLocation,
                               demoRuleIfMissing: Bool = false) async -> DemoScanConfiguration? {
        guard let database else { return nil }
        do {
            let adapter = try await SwiftDataCatalogReader.load(from: database, productID: product.id, location: location)
            let fallback = demoRuleIfMissing
                ? DetectionActivationRuleSnapshot(targetItemID: product.id, landmarkID: "demo",
                    activateAfterMeters: 0, deactivateAfterMeters: 100)
                : nil
            let rule = adapter.rule ?? fallback
            let catalog: any CatalogReading
            if adapter.rule == nil, let rule {
                catalog = OverlayRuleCatalog(base: adapter, rule: rule)
            } else {
                catalog = adapter
            }
            return DemoScanConfiguration(targetID: product.id, title: adapter.target.title,
                catalog: catalog, rule: rule, usesDatabase: true,
                catalogKey: adapter.target.tcin, visual: adapter.targetVisualMetadata)
        } catch { status = error.localizedDescription; return nil }
    }

    private func snapshots(from products: [CatalogProductRecord]) -> [CatalogItemSnapshot] {
        let normalizer = TextNormalizer()
        return products.map { record in
            let texts = [record.title] + record.aliases + (record.brand.map { [$0] } ?? [])
            return CatalogItemSnapshot(id: record.id, catalogKey: record.tcin, displayName: record.title,
                brand: record.brand, normalizedTerms: Set(texts.flatMap { normalizer.tokens(from: $0) }),
                itemType: record.itemType)
        }
    }
}

struct DemoBuyItem: Identifiable {
    var id: UUID { product.id }
    let product: CatalogProductRecord
    var collected = false
}

private struct OverlayRuleCatalog: CatalogReading {
    let base: SwiftDataCatalogReader
    let rule: DetectionActivationRuleSnapshot
    func catalogCandidates(for targetItemID: UUID) async throws -> [CatalogItemSnapshot] {
        try await base.catalogCandidates(for: targetItemID)
    }
    func activationRule(for targetItemID: UUID) async throws -> DetectionActivationRuleSnapshot? {
        try await base.activationRule(for: targetItemID) ?? rule
    }
}
