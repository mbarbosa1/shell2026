import Foundation

/// Word → aisle-candidate lookup built once per scan. OCR tokens resolve in one
/// dictionary read instead of comparing every observed word to every title.
public struct ShelfWordIndex: Sendable {
    public static let empty = ShelfWordIndex(candidates: [])

    private let byWord: [String: Set<UUID>]
    private let anchorsByItem: [UUID: Set<String>]

    public init(candidates: [CatalogItemSnapshot]) {
        var byWord: [String: Set<UUID>] = [:]
        var anchorsByItem: [UUID: Set<String>] = [:]
        for candidate in candidates {
            let anchors = ItemTypeAnchor.words(from: candidate.itemType)
            anchorsByItem[candidate.id] = anchors
            for word in anchors.union(CatalogMatcher.words(candidate.normalizedTerms)) {
                byWord[word, default: []].insert(candidate.id)
            }
        }
        self.byWord = byWord
        self.anchorsByItem = anchorsByItem
    }

    public func itemIDs(for word: String) -> Set<UUID> {
        byWord[word] ?? []
    }

    public func anchors(for itemID: UUID) -> Set<String> {
        anchorsByItem[itemID] ?? []
    }

    /// Products whose indexed words equal or start with any query token.
    public func itemIDs(matching query: String) -> Set<UUID> {
        let tokens = TextNormalizer().tokens(from: query).filter { !$0.contains(" ") }
        guard !tokens.isEmpty else { return [] }
        var result = Set<UUID>()
        for token in tokens {
            result.formUnion(itemIDs(for: token))
            for (word, ids) in byWord where word.hasPrefix(token) {
                result.formUnion(ids)
            }
        }
        return result
    }
}
