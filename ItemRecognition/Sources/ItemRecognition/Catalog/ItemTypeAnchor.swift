import Foundation

/// Printable item-type words used as OCR anchors. Fruit and vegetables have none;
/// those items stay on Apple Vision. Shelf wording (`cold cereals`) is reduced to
/// the word that actually appears on the package (`cereal`).
public enum ItemTypeAnchor: Sendable {
    private static let shelf: Set<String> = ["a", "an", "and", "of", "the", "cold", "fresh"]
    private static let normalizer = TextNormalizer()

    /// Normalized singular and plural forms of a packaged `itemType`. Empty when
    /// the type is missing, fruit, or vegetable.
    public static func words(from itemType: String?) -> Set<String> {
        guard let itemType else { return [] }
        let value = itemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "fruit", !value.hasPrefix("vegetable") else { return [] }
        var result = Set<String>()
        for token in normalizer.tokens(from: itemType) where !token.contains(" ") && !shelf.contains(token) {
            result.insert(token)
            if let singular = singular(of: token) { result.insert(singular) }
        }
        return result
    }

    /// Light English plural: `cereals` → `cereal`. Leaves `ss` endings alone.
    public static func singular(of word: String) -> String? {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return nil }
        return String(word.dropLast())
    }
}
