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
            result.formUnion(singulars(of: token))
        }
        return result
    }

    /// Light English plural, as every plausible singular. Dropping the `s` is kept
    /// (`cookies` → `cookie`, `sausages` → `sausage`); `-ies` also gives `-y`
    /// (`pastries` → `pastry`) and `-xes`/`-ches`/`-shes`/`-sses`/`-zes` also drop
    /// `es` (`mixes` → `mix`). A wrong extra form never appears on a package, so it
    /// cannot match. Leaves `ss` endings alone.
    public static func singulars(of word: String) -> [String] {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return [] }
        var forms = [String(word.dropLast())]
        if word.hasSuffix("ies") {
            forms.append(String(word.dropLast(3)) + "y")
        } else if ["xes", "ches", "shes", "sses", "zes"].contains(where: word.hasSuffix) {
            forms.append(String(word.dropLast(2)))
        }
        return forms
    }
}
