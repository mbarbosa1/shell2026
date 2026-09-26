// Compile-and-run check for the SwiftData models and importer, using an in-memory store.
// Needs full Xcode (SwiftData macros). run.sh uses it automatically when Xcode is selected, or:
//   swiftc -parse-as-library SwiftData/*.swift verify_import.swift -o .build/verify && .build/verify output/products.json

import Foundation
import SwiftData

@main
struct VerifyImport {
    @MainActor
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "output/products.json"
        let container = try ModelContainer(
            for: Product.self, StoreLocation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let first = try ProductImporter.importProducts(from: URL(fileURLWithPath: path), into: context)
        let second = try ProductImporter.importProducts(from: URL(fileURLWithPath: path), into: context)
        print("First import:  \(first.inserted) inserted, \(first.updated) updated, \(first.removed) removed")
        print("Second import: \(second.inserted) inserted, \(second.updated) updated (should insert 0)")
        let unlocated = try context.fetch(FetchDescriptor<Product>()).filter { $0.locations.isEmpty }
        precondition(unlocated.isEmpty, "found \(unlocated.count) products without a location")

        let products = try context.fetch(FetchDescriptor<Product>(sortBy: [SortDescriptor(\.title)]))
        let locations = try context.fetchCount(FetchDescriptor<StoreLocation>())
        print("Products: \(products.count), store locations: \(locations)")

        let aisle44 = try context.fetch(FetchDescriptor<StoreLocation>(predicate: #Predicate { $0.block == "G" && $0.aisle == 44 }))
        print("\nIn G44 (\(aisle44.count)):")
        for loc in aisle44.prefix(5) {
            print("  \(loc.product?.title ?? "?") — \(loc.product?.itemType ?? "")")
        }

        print("\nSample:")
        for p in products.filter({ !$0.locations.isEmpty }).prefix(5) {
            let where_ = p.locations.map { "\($0.label) (floor \($0.floor))" }.joined(separator: ", ")
            print("  [\(p.tcin)] \(p.title) — \(p.formattedPrice ?? "n/a") — \(Int(p.quantityAvailable ?? 0)) in stock — \(where_)")
        }
    }
}
