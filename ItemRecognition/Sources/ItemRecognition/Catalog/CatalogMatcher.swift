import CoreGraphics
import Foundation

public struct CatalogMatch: Sendable, Equatable {
    public let itemID: UUID
    public let score: Float
    public let matchedTerms: Set<String>
    public let conflicts: Set<String>
}

/// Conservative lexical MVP over a preloaded shelf candidate set. A score is
/// evidence coverage, not a calibrated probability. No persistence or product
/// names are owned here; all identity evidence comes from catalog snapshots.
///
/// Packaged items whose name contains their `itemType` word only score words
/// sitting next to that printed anchor. Other snapshots keep a bag-of-lines match.
public struct CatalogMatcher: Sendable {
    private let normalizer = TextNormalizer()
    static let generic: Set<String> = ["a", "an", "the", "and", "of", "with", "for", "new", "original", "family", "pack", "size", "-"]
    /// Centers within this many anchor-line heights belong to the same package.
    public static let neighborhoodHeights: CGFloat = 2
    public init() {}

    /// With a `query`, the target is scored on the shopper's grocery-list words
    /// (see `matchQuery`); other products keep their title scores.
    public func match(_ observation: ProductTextObservation, against candidates: [CatalogItemSnapshot],
                      requireDiscriminatingTerms: Bool = false, targetID: UUID? = nil,
                      index: ShelfWordIndex? = nil, query: GroceryQuery? = nil) -> [CatalogMatch] {
        let titled = matchTitles(observation, against: candidates, requireDiscriminatingTerms: requireDiscriminatingTerms,
                                 targetID: targetID, index: index)
        let targetItem = candidates.first { $0.id == (targetID ?? observation.targetItemID) }
        guard let query, !query.words.isEmpty, let targetItem else { return titled }
        return matchQuery(query, lines: observation.candidates, target: targetItem, against: candidates, titleMatches: titled)
    }

    private func matchTitles(_ observation: ProductTextObservation, against candidates: [CatalogItemSnapshot],
                             requireDiscriminatingTerms: Bool, targetID: UUID?,
                             index: ShelfWordIndex?) -> [CatalogMatch] {
        let target = targetID.flatMap { id in candidates.first { $0.id == id } } ?? candidates.first { $0.id == observation.targetItemID }
        let anchors = target.map { index?.anchors(for: $0.id) ?? ItemTypeAnchor.words(from: $0.itemType) } ?? []
        // The type word is only required when the product's own name uses it: oatmeal
        // is typed "Porridges" but never prints that word, so it matches on its name.
        if let target, target.itemType != nil, !target.recognizesByAppearance,
           !anchors.isDisjoint(with: Self.words(target.normalizedTerms)) {
            return matchNearAnchor(observation, anchors: anchors, against: candidates, index: index,
                                   requireDiscriminatingTerms: requireDiscriminatingTerms)
        }
        return score(confidence: bag(observation, index: index), against: candidates,
                     requireDiscriminatingTerms: requireDiscriminatingTerms)
    }

    static func words(_ terms: Set<String>) -> Set<String> {
        Set(terms.filter { !$0.contains(" ") && !generic.contains($0) && $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) })
    }

    private func matchNearAnchor(_ observation: ProductTextObservation, anchors: Set<String>,
                                 against candidates: [CatalogItemSnapshot], index: ShelfWordIndex?,
                                 requireDiscriminatingTerms: Bool) -> [CatalogMatch] {
        guard !anchors.isEmpty else { return zeros(candidates) }
        let lines = observation.candidates.compactMap { line -> LineTerms? in
            guard line.confidence.isFinite else { return nil }
            return LineTerms(words: Self.words(normalizer.tokens(from: line.normalizedText)),
                             confidence: min(max(line.confidence, 0), 1), box: line.boundingBox)
        }
        let anchorLines = lines.filter { !$0.words.isDisjoint(with: anchors) }
        guard !anchorLines.isEmpty else { return zeros(candidates) }

        var unused = Set(anchorLines.indices)
        var clusterScores: [[CatalogMatch]] = []
        while let seed = unused.min() {
            unused.remove(seed)
            var group = [anchorLines[seed]]
            var queue = [seed]
            while let current = queue.popLast() {
                for other in unused where Self.near(anchorLines[current].box, anchorLines[other].box) {
                    unused.remove(other)
                    group.append(anchorLines[other])
                    queue.append(other)
                }
            }
            let neighbors = lines.filter { line in group.contains { Self.near($0.box, line.box) } }
            clusterScores.append(score(confidence: bag(neighbors, index: index), against: candidates,
                                       requireDiscriminatingTerms: requireDiscriminatingTerms))
        }
        let scoring = clusterScores.filter { $0.contains { $0.score > 0 } }
        return scoring.count == 1 ? scoring[0] : zeros(candidates)
    }

    private func bag(_ observation: ProductTextObservation, index: ShelfWordIndex?) -> [String: Float] {
        bag(observation.candidates.compactMap { line -> LineTerms? in
            guard line.confidence.isFinite else { return nil }
            return LineTerms(words: Self.words(normalizer.tokens(from: line.normalizedText)),
                             confidence: min(max(line.confidence, 0), 1), box: line.boundingBox)
        }, index: index)
    }

    private func bag(_ lines: [LineTerms], index: ShelfWordIndex?) -> [String: Float] {
        var confidence: [String: Float] = [:]
        for line in lines {
            for term in line.words {
                if let index, index.itemIDs(for: term).isEmpty { continue }
                confidence[term] = max(confidence[term] ?? 0, line.confidence)
            }
        }
        return confidence
    }

    private func score(confidence: [String: Float], against candidates: [CatalogItemSnapshot],
                       requireDiscriminatingTerms: Bool) -> [CatalogMatch] {
        let observed = Set(confidence.keys)
        let evidence = candidates.map { Self.words($0.normalizedTerms) }
        return candidates.enumerated().map { index, candidate in
            let expected = evidence[index]
            let matched = expected.intersection(observed)
            var conflicts = Set<String>()
            if requireDiscriminatingTerms {
                let identifiers = expected.filter { $0.contains(where: \.isNumber) }
                conflicts.formUnion(identifiers.subtracting(observed).map { "missing:\($0)" })
                if let brand = candidate.brand {
                    conflicts.formUnion(Self.words(normalizer.tokens(from: normalizer.normalize(brand)))
                        .subtracting(observed).map { "missing:\($0)" })
                }
            }
            // Distinguish close variants; seeing a neighboring variant's unique
            // terms makes this candidate unsafe to confirm, even if names overlap.
            for other in evidence.indices where other != index {
                let shared = expected.intersection(evidence[other])
                guard shared.count >= 2, !expected.subtracting(evidence[other]).isEmpty else { continue }
                conflicts.formUnion(evidence[other].subtracting(expected).intersection(observed))
                if requireDiscriminatingTerms {
                    conflicts.formUnion(expected.subtracting(evidence[other]).subtracting(observed).map { "missing:\($0)" })
                }
            }
            let weighted = matched.reduce(Float(0)) { $0 + (confidence[$1] ?? 0) }
            // Two matched words, unless the whole name is one word ("Milk" on a grocery list).
            let needed = min(2, expected.count)
            let score = expected.isEmpty || matched.count < needed || !conflicts.isEmpty ? 0 : weighted / Float(expected.count)
            return CatalogMatch(itemID: candidate.id, score: score, matchedTerms: matched, conflicts: conflicts)
        }.sorted { $0.score == $1.score ? $0.itemID.uuidString < $1.itemID.uuidString : $0.score > $1.score }
    }

    private func zeros(_ candidates: [CatalogItemSnapshot]) -> [CatalogMatch] {
        candidates.map { CatalogMatch(itemID: $0.id, score: 0, matchedTerms: [], conflicts: []) }
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    }

    /// Centers within two line-heights share a package. Uses the taller line so
    /// a short size line still attaches to a tall product-name line.
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = max(max(a.height, b.height), 0.0001)
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy <= (neighborhoodHeights * height) * (neighborhoodHeights * height)
    }

    private struct LineTerms {
        let words: Set<String>
        let confidence: Float
        let box: CGRect
    }
}
