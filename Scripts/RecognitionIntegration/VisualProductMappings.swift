import Foundation
import ItemRecognition

/// The reviewed mapping file ships with catalog integration (`Resources/`); its parser,
/// `VisualProductMappings`, lives in ItemRecognition so apps without this target can read it too.
extension VisualProductMappings {
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "visual-product-mappings", withExtension: "json") else {
            throw MappingError.missingResource
        }
        return try Self(data: Data(contentsOf: url))
    }
}
