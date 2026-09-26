import Foundation

public struct VisualCatalogMatch: Sendable, Equatable {
    public enum Reason: String, Sendable {
        /// SKU-level model: the class uniquely identifies this catalog item.
        case accepted
        /// MVP broad-category model: "onion" confirms the selected onion product.
        /// Variety, organic status, size and brand are not verified.
        case acceptedCategory
        case insufficientEvidence, categoryOnly, ambiguousCatalog
    }
    public let score: Float
    public let classID: String?
    public let reason: Reason
    public var accepted: Bool { reason == .accepted || reason == .acceptedCategory }
}

public struct VisualCatalogMatcher: Sendable {
    public init() {}

    public func match(_ observation: VisualObservation, targetID: UUID,
                      against candidates: [CatalogItemSnapshot],
                      policy: VisualRecognitionPolicy) throws -> VisualCatalogMatch {
        guard let metadata = candidates.first(where: { $0.id == targetID })?.visual,
              metadata.modelID == observation.modelID else {
            throw VisualRecognitionError.incompatibleModel
        }
        let predictions = observation.classifications
        guard predictions.allSatisfy({ !$0.identifier.isEmpty && $0.score.isFinite && (0...1).contains($0.score) }),
              Set(predictions.map(\.identifier)).count == predictions.count else {
            throw VisualRecognitionError.invalidObservation
        }
        let matching = predictions.filter { metadata.classIDs.contains($0.identifier) }
            .sorted { $0.score > $1.score }
        let score = matching.first?.score ?? 0
        let classID = matching.first?.identifier
        // Every competing model label counts, not only those stocked in the aisle.
        // Exception: the MVP taxonomy folds all non-produce labels ("table", "hand")
        // into `unknown`, and Vision scores labels independently, so a table at 73%
        // does not contradict an onion. There only other produce labels compete.
        let competing = predictions.filter {
            !metadata.classIDs.contains($0.identifier) &&
            !(metadata.modelID == ProduceCategoryClassifier.modelID && $0.identifier == "unknown")
        }
        let otherScore = competing.map(\.score).max() ?? 0
        guard score > 0, score >= policy.minimumScore else {
            return VisualCatalogMatch(score: score, classID: classID, reason: .insufficientEvidence)
        }
        guard score - otherScore >= policy.minimumMargin else {
            return VisualCatalogMatch(score: score, classID: classID, reason: .insufficientEvidence)
        }
        // Raw Vision labels are an unreviewed vocabulary; only the MVP taxonomy
        // or a validated custom model may confirm.
        guard metadata.allowsConfirmation, metadata.modelID != VisionImageClassifier.modelID else {
            return VisualCatalogMatch(score: score, classID: classID, reason: .categoryOnly)
        }
        // Neighbors sharing "apple" are expected at category level; the selected
        // target is confirmed as that category, not as a verified variety.
        if metadata.modelID == ProduceCategoryClassifier.modelID {
            return VisualCatalogMatch(score: score, classID: classID, reason: .acceptedCategory)
        }
        let ambiguous = candidates.contains { candidate in
            guard candidate.id != targetID, let other = candidate.visual,
                  other.modelID == metadata.modelID else { return false }
            return !other.classIDs.isDisjoint(with: metadata.classIDs)
        }
        return VisualCatalogMatch(score: score, classID: classID,
                                  reason: ambiguous ? .ambiguousCatalog : .accepted)
    }
}
