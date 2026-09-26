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
    /// How closely this one frame matches the selected product, 0...1. Relative
    /// to competing labels (background excluded for the MVP taxonomy) and scaled
    /// so reaching `minimumScore` alone counts as full strength. 0 below the
    /// noise floor. Not a calibrated probability.
    public let confidence: Float
    public var accepted: Bool { reason == .accepted || reason == .acceptedCategory }

    public init(score: Float, classID: String?, reason: Reason, confidence: Float = 0) {
        self.score = score; self.classID = classID; self.reason = reason; self.confidence = confidence
    }

    static func confidence(target: Float, competing: Float, kind: VisualObservation.Kind,
                           policy: VisualRecognitionPolicy) -> Float {
        guard target > 0, target >= policy.noiseFloor else { return 0 }
        // A cloud answer is one label with the provider's own confidence.
        if kind == .cloudSuggestion { return min(target, 1) }
        let share = target / (target + competing)
        let strength = policy.minimumScore > 0 ? min(target / policy.minimumScore, 1) : 1
        return min(max(share * strength, 0), 1)
    }
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
        let confidence = VisualCatalogMatch.confidence(target: score, competing: competing.map(\.score).reduce(0, +),
                                                       kind: observation.kind, policy: policy)
        func match(_ reason: VisualCatalogMatch.Reason) -> VisualCatalogMatch {
            VisualCatalogMatch(score: score, classID: classID, reason: reason, confidence: confidence)
        }
        guard score > 0, score >= policy.minimumScore else { return match(.insufficientEvidence) }
        guard score - otherScore >= policy.minimumMargin else { return match(.insufficientEvidence) }
        // Raw Vision labels are an unreviewed vocabulary; only the MVP taxonomy
        // or a validated custom model may confirm.
        guard metadata.allowsConfirmation, metadata.modelID != VisionImageClassifier.modelID else {
            return match(.categoryOnly)
        }
        // Neighbors sharing "apple" are expected at category level; the selected
        // target is confirmed as that category, not as a verified variety.
        if metadata.modelID == ProduceCategoryClassifier.modelID { return match(.acceptedCategory) }
        let ambiguous = candidates.contains { candidate in
            guard candidate.id != targetID, let other = candidate.visual,
                  other.modelID == metadata.modelID else { return false }
            return !other.classIDs.isDisjoint(with: metadata.classIDs)
        }
        return match(ambiguous ? .ambiguousCatalog : .accepted)
    }
}
