// Checks that products.json decodes into the Swift DTOs. Needs only Foundation,
// so it runs with Command Line Tools (verify_import.swift needs full Xcode for SwiftData macros).
//   swiftc -parse-as-library SwiftData/ProductDTO.swift verify_decode.swift -o .build/verify_decode
// backup for when you only have Command Line Tools installed. It just checks that the JSON file can be read.
import Foundation

@main
struct VerifyDecode {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "output/products.json"
        let file = try JSONDecoder().decode(ProductFileDTO.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let located = file.products.filter(\.hasLocation)
        print("Decoded \(file.products.count) products (\(located.count) with aisle/block)")
        for p in located.prefix(5) {
            let where_ = (p.locations ?? []).map { ($0.aisle ?? "?") }.joined(separator: ", ")
            print("  [\(p.tcin)] \(p.title ?? "?") — \(p.formattedPrice ?? "n/a") — \(Int(p.quantityAvailable ?? 0)) in stock — \(where_)")
        }
    }
}
