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
                    Button("Camera only (no database)") { scan = .ocrOnly }
                    Text(model.status).font(.caption)
                    Button("Reload bundled catalog") { Task { await model.load() } }
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
            .fullScreenCover(item: $scan) { CameraDemoView(configuration: $0) }
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
    private var database: ProductDatabaseStore?
    var selectedProduct: CatalogProductRecord? { products.first { $0.id == selectedID } }
    var location: CatalogLocation? { selectedProduct?.locations.first { $0.id == locationID } }

    func load() async {
        do {
            let db: ProductDatabaseStore
            if let database { db = database } else { db = try ProductDatabaseStore(); database = db }
            guard let url = Bundle.main.url(forResource: "products", withExtension: "json") else {
                status = "Missing bundled products.json."; return
            }
            let changed = try await db.importProducts(Data(contentsOf: url))
            products = try await db.products()
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
        guard let database, let selectedID, let location else { return nil }
        do {
            let adapter = try await SwiftDataCatalogReader.load(from: database, productID: selectedID, location: location)
            return DemoScanConfiguration(targetID: selectedID, title: adapter.target.title,
                catalog: adapter, rule: adapter.rule, usesDatabase: true,
                catalogKey: adapter.target.tcin, visual: adapter.targetVisualMetadata)
        } catch { status = error.localizedDescription; return nil }
    }
}
