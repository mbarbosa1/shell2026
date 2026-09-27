import CoreGraphics
import Foundation

/// One line of text Vision read from the processed region, with the same text
/// after `TextNormalizing`.
///
/// `boundingBox` is Vision's normalized rectangle for the line (origin lower-left, relative
/// to the whole oriented image) and is carried so a later matcher can reason about
/// where on the package a term appeared.
public struct RecognizedTextCandidate: Sendable, Hashable {
    public let rawText: String
    public let normalizedText: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(rawText: String, normalizedText: String, confidence: Float, boundingBox: CGRect) {
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// The output of the text extraction slice: what OCR read from one supplied
/// image while the activation gate was `.active`.
///
/// `boundingBox` is the region OCR ran on, in stored-buffer pixel coordinates
/// with a top-left origin: the caller's crop when one was supplied, otherwise
/// the automatically detected, padded region. `side` is copied from the activation rule and stays `nil`
/// when the database branch supplied none; it is metadata only.
///
/// An observation with an empty `candidates` array means OCR ran and found no text.
/// A `nil` return means the frame was skipped or its result was discarded.
public struct ProductTextObservation: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let targetItemID: UUID
    public let boundingBox: CGRect
    public let candidates: [RecognizedTextCandidate]
    public let side: ShelfSide?

    public init(
        timestamp: TimeInterval,
        targetItemID: UUID,
        boundingBox: CGRect,
        candidates: [RecognizedTextCandidate],
        side: ShelfSide?
    ) {
        self.timestamp = timestamp
        self.targetItemID = targetItemID
        self.boundingBox = boundingBox
        self.candidates = candidates
        self.side = side
    }
}
