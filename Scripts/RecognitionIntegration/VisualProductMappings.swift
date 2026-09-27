import Foundation
import ItemRecognition

/// Versioned demo metadata owned by catalog integration. No product names,
/// recognition UUIDs, prices, images, or activation values are duplicated.
public struct VisualProductMappings: Sendable {
    private struct File: Decodable {
        let version: Int
        let products: [Entry]
    }
    private struct Entry: Decodable {
        let tcin: String
        let visual: VisualCatalogMetadata
    }
    private let entries: [String: VisualCatalogMetadata]

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == 1, Set(file.products.map(\.tcin)).count == file.products.count,
              file.products.allSatisfy({ entry in
                  !entry.tcin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !entry.visual.modelID.isEmpty && !entry.visual.classIDs.isEmpty &&
                  entry.visual.classIDs.allSatisfy { !$0.isEmpty } &&
                  // Raw Vision labels are unreviewed; confirm through the MVP taxonomy instead.
                  (entry.visual.modelID != VisionImageClassifier.modelID || !entry.visual.allowsConfirmation)
              }) else { throw MappingError.invalidMapping }
        entries = Dictionary(uniqueKeysWithValues: file.products.map { ($0.tcin, $0.visual) })
    }
    public func metadata(for tcin: String) -> VisualCatalogMetadata? { entries[tcin] }
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "visual-product-mappings", withExtension: "json") else {
            throw MappingError.missingResource
        }
        return try Self(data: Data(contentsOf: url))
    }
    public enum MappingError: Error, LocalizedError {
        case invalidMapping, missingResource
        public var errorDescription: String? {
            switch self {
            case .invalidMapping: return "The visual product mapping is invalid or enables unsupported exact-product confirmation."
            case .missingResource: return "The visual product mapping resource is missing."
            }
        }
    }
}
