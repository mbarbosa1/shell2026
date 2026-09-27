import Foundation

/// Picks the one catalog product we think the user means by a grocery item.
///
/// 1. The product's own name (the part before " - ") has every word of the item and ends with its
///    main word, so "bananas" finds "Fresh Banana", not "Banana Nut Granola".
/// 2. If the user named a brand, prefer that brand. No brand means any brand is fine.
/// 3. If the item has a label ("2%", "large brown"), prefer products that mention the most of it.
/// 4. Of what's left, the cheapest.
enum ProductMatcher {
    static func bestProduct(name: String, label: String?, brand: String?, in products: [Product]) -> Product? {
        let wanted = words(name)
        guard let mainWord = wanted.last else { return nil }

        var candidates = products.filter { product in
            let productName = words(ownName(of: product.title))
            return product.soldOut != true && productName.last == mainWord && Set(wanted).isSubset(of: productName)
        }
        if let brand, !brand.isEmpty {
            let brandWords = Set(words(brand))
            let branded = candidates.filter { brandWords.isSubset(of: words($0.title)) }
            if !branded.isEmpty { candidates = branded }
        }
        if let label, !label.isEmpty {
            let labelWords = Set(words(label))
            func overlap(_ product: Product) -> Int { labelWords.intersection(words(product.title)).count }
            let most = candidates.map(overlap).max() ?? 0
            candidates = candidates.filter { overlap($0) == most }
        }
        return candidates.min { ($0.currentPrice ?? .infinity) < ($1.currentPrice ?? .infinity) }
    }

    /// "Fresh Banana - each - Good & Gather™" → "Fresh Banana". The tagline after ":" is dropped
    /// too, so butter's "Whole Milk Fat" doesn't make it whole milk.
    static func ownName(of title: String) -> String {
        title.components(separatedBy: ":")[0]
            .replacingOccurrences(of: " – ", with: " - ")
            .components(separatedBy: " - ")[0]
    }

    /// Lowercased words, with plurals folded so "Cookies"/"cookie" and "berries"/"berry" compare equal.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "%" }
            .map { word in
                var word = String(word)
                if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
                if word.count > 3, word.hasSuffix("y") { word = String(word.dropLast()) + "ie" }
                return word
            }
    }
}
