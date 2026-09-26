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
public struct CatalogMatcher: Sendable {
    private let normalizer = TextNormalizer()
    private let generic: Set<String> = ["a", "an", "the", "and", "of", "with", "for", "new", "original", "family", "pack", "size", "-"]
    public init() {}

    public func match(_ observation: ProductTextObservation, against candidates: [CatalogItemSnapshot]) -> [CatalogMatch] {
        var confidence: [String: Float] = [:]
        for line in observation.candidates where line.confidence.isFinite {
            let value = min(max(line.confidence, 0), 1)
            for term in words(normalizer.tokens(from: line.normalizedText)) {
                confidence[term] = max(confidence[term] ?? 0, value)
            }
        }
        let observed = Set(confidence.keys)
        let evidence = candidates.map { words($0.normalizedTerms) }
        return candidates.enumerated().map { index, candidate in
            let expected = evidence[index]
            let matched = expected.intersection(observed)
            var conflicts = Set<String>()
            // Distinguish close variants; seeing a neighboring variant's unique
            // terms makes this candidate unsafe to confirm, even if names overlap.
            for other in evidence.indices where other != index {
                let shared = expected.intersection(evidence[other])
                guard shared.count >= 2, !expected.subtracting(evidence[other]).isEmpty else { continue }
                conflicts.formUnion(evidence[other].subtracting(expected).intersection(observed))
            }
            let weighted = matched.reduce(Float(0)) { $0 + (confidence[$1] ?? 0) }
            let score = expected.isEmpty || matched.count < 2 || !conflicts.isEmpty ? 0 : weighted / Float(expected.count)
            return CatalogMatch(itemID: candidate.id, score: score, matchedTerms: matched, conflicts: conflicts)
        }.sorted { $0.score == $1.score ? $0.itemID.uuidString < $1.itemID.uuidString : $0.score > $1.score }
    }

    private func words(_ terms: Set<String>) -> Set<String> {
        Set(terms.filter { !$0.contains(" ") && !generic.contains($0) && $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) })
    }
}
