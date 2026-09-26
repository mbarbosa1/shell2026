import SwiftData
import SwiftUI

@main
struct ShellApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Product.self, StoreLocation.self)
            // Re-import every launch so a regenerated products.json (./Scripts/run.sh) shows up.
            // The importer upserts by TCIN, so this never duplicates products.
            try ProductImporter.importBundledProducts(into: container.mainContext)
        } catch {
            fatalError("Could not set up the product database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
