import CoreGraphics
import Foundation

/// The object whose own text the catalog matched to the target, when several
/// objects were in view. Text on the other objects never reaches its score.
public struct ObjectTextMatch: Sendable, Equatable {
    /// Normalized lower-left box in the oriented image, as the assessor reported it.
    public let objectBox: CGRect
    /// Only the lines whose centres sit on `objectBox`.
    public let observation: ProductTextObservation
    public let matches: [CatalogMatch]
}

extension CatalogMatcher {
    /// Splits one OCR pass into per-object groups, in `objectBoxes` order. A line
    /// belongs to the smallest box containing its centre, so a label on a jug in
    /// front of a case goes to the jug. Lines on no object are dropped.
    public static func group(_ observation: ProductTextObservation,
                             by objectBoxes: [CGRect]) -> [(box: CGRect, observation: ProductTextObservation)] {
        var lines = Array(repeating: [RecognizedTextCandidate](), count: objectBoxes.count)
        for line in observation.candidates {
            let centre = CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY)
            let owner = objectBoxes.indices.filter { objectBoxes[$0].contains(centre) }
                .min { objectBoxes[$0].width * objectBoxes[$0].height < objectBoxes[$1].width * objectBoxes[$1].height }
            if let owner { lines[owner].append(line) }
        }
        return objectBoxes.indices.map { index in
            (objectBoxes[index], ProductTextObservation(timestamp: observation.timestamp,
                targetItemID: observation.targetItemID, boundingBox: observation.boundingBox,
                candidates: lines[index], side: observation.side))
        }
    }

    /// Scores each object's text on its own against the aisle candidates and
    /// returns the object the catalog ties to the target: the highest target
    /// score, then the box nearer the frame centre (two facings of the same
    /// product are both correct). Nil when no object's text scores for the target.
    public func matchPerObject(_ observation: ProductTextObservation, objectBoxes: [CGRect],
                               against candidates: [CatalogItemSnapshot], requireDiscriminatingTerms: Bool = false,
                               targetID: UUID, index: ShelfWordIndex? = nil,
                               query: GroceryQuery? = nil) -> ObjectTextMatch? {
        let scored = Self.group(observation, by: objectBoxes).compactMap { box, lines -> (ObjectTextMatch, Float)? in
            guard !lines.candidates.isEmpty else { return nil }
            let matches = match(lines, against: candidates, requireDiscriminatingTerms: requireDiscriminatingTerms,
                                targetID: targetID, index: index, query: query)
            let score = matches.first { $0.itemID == targetID }?.score ?? 0
            guard score > 0 else { return nil }
            return (ObjectTextMatch(objectBox: box, observation: lines, matches: matches), score)
        }
        return scored.min { a, b in
            a.1 != b.1 ? a.1 > b.1 : Self.centreDistance(a.0.objectBox) < Self.centreDistance(b.0.objectBox)
        }?.0
    }

    private static func centreDistance(_ box: CGRect) -> CGFloat {
        hypot(box.midX - 0.5, box.midY - 0.5)
    }
}
