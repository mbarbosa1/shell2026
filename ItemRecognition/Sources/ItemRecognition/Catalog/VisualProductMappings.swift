import Foundation

/// Which catalog products are recognized by appearance, and as which produce class, keyed by TCIN.
/// Read from the reviewed `visual-product-mappings.json`, which the database branch owns and ships
/// (`Scripts/RecognitionIntegration/Resources/`); apps that bundle the same file load it with
/// `init(data:)`. No product names, recognition UUIDs, prices, images, or activation values are
/// duplicated.
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
