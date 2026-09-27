import Foundation

/// What the shopper put on the grocery list ("2% milk", "Doritos Cool Ranch"). When a
/// scan has one, the package must show these words, not the catalog's long scraped
/// title. Size is left out: it is printed small and apps often fill it from the catalog.
public struct GroceryQuery: Sendable, Hashable {
    public let name: String
    public let brand: String?
    public let label: String?

    public init(name: String, brand: String? = nil, label: String? = nil) {
        self.name = name; self.brand = brand; self.label = label
    }

    /// "Doritos Cool Ranch", "2% milk": the name used when the shopper is asked.
    public var displayName: String {
        [brand, label, name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Normalized single words the package must show. Generic words ("the", "pack") are dropped.
    public var words: Set<String> {
        CatalogMatcher.words(TextNormalizer().tokens(from: displayName))
    }
}

/// The target's evidence against a grocery-list entry, from one group of nearby lines.
struct QueryReading {
    /// Share of the list words read, each weighted by how closely it was read and by OCR confidence.
    let score: Float
    /// List words that were read, exactly or approximately.
    let matched: Set<String>
    /// Every word in the group that scored best, for checking competing products.
    let read: Set<String>
}

extension CatalogMatcher {
    /// Scores the list entry instead of the catalog title for the target. Other aisle
    /// products still compete: one that the list entry does not describe blocks the
    /// match when its own distinguishing name words were read beside the list words,
    /// and it keeps its title score so the coordinator's lead check still applies.
    /// Products the list entry also describes ("Doritos" fits both flavors) do not
    /// compete; any of them fulfils the list.
    func matchQuery(_ query: GroceryQuery, lines: [RecognizedTextCandidate], target: CatalogItemSnapshot,
                    against candidates: [CatalogItemSnapshot], titleMatches: [CatalogMatch]) -> [CatalogMatch] {
        let wanted = query.words
        let reading = Self.read(wanted, in: lines)
        let targetWords = Self.words(target.normalizedTerms)
        var conflicts = Set<String>()
        var fulfilling: Set<UUID> = [target.id]
        for candidate in candidates where candidate.id != target.id {
            if Self.describes(wanted, candidate) { fulfilling.insert(candidate.id); continue }
            let own = Self.words(TextNormalizer().tokens(from: Self.ownName(candidate.displayName)))
                .subtracting(wanted).subtracting(targetWords)
            let seen = own.intersection(reading.read)
            if !own.isEmpty, seen.count >= min(2, own.count) { conflicts.formUnion(seen) }
        }
        let targetMatch = CatalogMatch(itemID: target.id, score: conflicts.isEmpty ? reading.score : 0,
                                       matchedTerms: reading.matched, conflicts: conflicts)
        return titleMatches.map { match in
            if match.itemID == target.id { return targetMatch }
            guard fulfilling.contains(match.itemID) else { return match }
            return CatalogMatch(itemID: match.itemID, score: 0, matchedTerms: match.matchedTerms, conflicts: [])
        }.sorted { $0.score == $1.score ? $0.itemID.uuidString < $1.itemID.uuidString : $0.score > $1.score }
    }

    /// Lines are grouped by proximity (chains of lines within `neighborhoodHeights` of
    /// each other, i.e. one package) and each group is scored alone, so list words
    /// scattered over a shelf tag and two packages never add up. The best group wins.
    static func read(_ wanted: Set<String>, in lines: [RecognizedTextCandidate]) -> QueryReading {
        let usable = lines.filter { $0.confidence.isFinite }
        guard !wanted.isEmpty, !usable.isEmpty else { return QueryReading(score: 0, matched: [], read: []) }
        var best = QueryReading(score: 0, matched: [], read: [])
        for group in proximityGroups(usable) {
            var read: [String: Float] = [:]
            for line in group {
                for word in words(TextNormalizer().tokens(from: line.normalizedText)) {
                    read[word] = max(read[word] ?? 0, min(max(line.confidence, 0), 1))
                }
            }
            var total: Float = 0
            var matched = Set<String>()
            for word in wanted {
                let credit = read.map { similarity(word, $0.key) * $0.value }.max() ?? 0
                if credit > 0 { matched.insert(word); total += credit }
            }
            let score = total / Float(wanted.count)
            if score > best.score { best = QueryReading(score: score, matched: matched, read: Set(read.keys)) }
        }
        return best
    }

    static func proximityGroups(_ lines: [RecognizedTextCandidate]) -> [[RecognizedTextCandidate]] {
        var unused = Set(lines.indices)
        var groups: [[RecognizedTextCandidate]] = []
        while let seed = unused.min() {
            unused.remove(seed)
            var group = [seed]
            var queue = [seed]
            while let current = queue.popLast() {
                for other in unused where near(lines[current].boundingBox, lines[other].boundingBox) {
                    unused.remove(other); group.append(other); queue.append(other)
                }
            }
            groups.append(group.sorted().map { lines[$0] })
        }
        return groups
    }

    /// How closely a read word matches a list word, 0...1. Plurals, hyphens and
    /// apostrophes do not matter ("cookie"/"COOKIES", "cheezit"/"Cheez-It"). Words
    /// with digits and words under four letters must match exactly. Longer words
    /// tolerate OCR slips: one wrong letter up to seven letters, two from eight,
    /// and earn less credit the more letters differ.
    static func similarity(_ wanted: String, _ read: String) -> Float {
        let a = folded(wanted), b = folded(read)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b || ItemTypeAnchor.singulars(of: a).contains(b) || ItemTypeAnchor.singulars(of: b).contains(a) { return 1 }
        let length = max(a.count, b.count)
        guard length >= 4, !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return 0 }
        let distance = editDistance(Array(a), Array(b))
        guard distance <= (length >= 8 ? 2 : 1) else { return 0 }
        return 1 - Float(distance) / Float(length)
    }

    /// True when the product's name and terms contain every list word, so it fulfils the list.
    static func describes(_ wanted: Set<String>, _ candidate: CatalogItemSnapshot) -> Bool {
        let own = words(candidate.normalizedTerms)
        return !wanted.isEmpty && wanted.allSatisfy { word in own.contains { similarity(word, $0) > 0 } }
    }

    /// "Fresh Banana - each - Good & Gather™" → "Fresh Banana"; a tagline after ":" is dropped too.
    static func ownName(_ title: String) -> String {
        let name = title.components(separatedBy: ":")[0].replacingOccurrences(of: " – ", with: " - ")
        return name.components(separatedBy: " - ")[0]
    }

    private static func folded(_ word: String) -> String {
        word.filter { $0 != "-" && $0 != "'" && $0 != "’" }
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
