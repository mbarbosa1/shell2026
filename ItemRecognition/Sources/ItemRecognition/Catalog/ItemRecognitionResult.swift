import Foundation

public enum RecognitionEvidenceSource: String, Sendable {
    case ocr, visual
}

public struct ItemRecognitionResult: Sendable, Equatable {
    public enum Status: String, Sendable { case confirmed, candidate, noMatch, disabled }
    public let timestamp: TimeInterval
    public let targetItemID: UUID
    public let matchedItemID: UUID?
    public let normalizedObservedText: Set<String>
    /// Raw evidence score for the selected product in this frame.
    public let score: Float
    public let status: Status
    /// How closely the recent frames match the selected product, 0...1, averaged
    /// over the last few processed frames. 1 means the selected label clearly
    /// dominates; 0 means it is absent (a cereal box while looking for onion).
    /// Independent of `status`; not a calibrated probability.
    public let matchConfidence: Float
    public let evidenceSource: RecognitionEvidenceSource
    public let visualEvidence: VisualObservation?
    public let visualMatchReason: VisualCatalogMatch.Reason?

    public init(timestamp: TimeInterval, targetItemID: UUID, matchedItemID: UUID?,
                normalizedObservedText: Set<String>, score: Float, status: Status,
                matchConfidence: Float = 0,
                evidenceSource: RecognitionEvidenceSource = .ocr,
                visualEvidence: VisualObservation? = nil,
                visualMatchReason: VisualCatalogMatch.Reason? = nil) {
        self.timestamp = timestamp; self.targetItemID = targetItemID; self.matchedItemID = matchedItemID
        self.normalizedObservedText = normalizedObservedText; self.score = score; self.status = status
        self.matchConfidence = matchConfidence
        self.evidenceSource = evidenceSource; self.visualEvidence = visualEvidence
        self.visualMatchReason = visualMatchReason
    }
}

public struct ItemObservation: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let itemID: UUID
    /// Evidence score, not a calibrated probability.
    public let matchConfidence: Float
    public let observedTerms: Set<String>
    public let side: ShelfSide?
    public let evidenceSource: RecognitionEvidenceSource
    public let visualEvidence: VisualObservation?
}

public struct RecognitionPolicy: Sendable {
    public let requireDiscriminatingTerms: Bool
    public let minimumScore: Float
    public let minimumMargin: Float
    public let requiredObservations: Int
    public let maximumGap: TimeInterval
    /// Defaults ask the shopper after one clear frame: the target scores at least
    /// 0.4 of its title words, leads every other aisle product by 0.15, and no
    /// neighbor's distinguishing word was read. The shopper's answer is the final
    /// check, so repeated frames only delayed the question (user decision).
    public init(minimumScore: Float = 0.4, minimumMargin: Float = 0.15,
                requiredObservations: Int = 1, maximumGap: TimeInterval = 2,
                requireDiscriminatingTerms: Bool = false) {
        self.requireDiscriminatingTerms = requireDiscriminatingTerms
        self.minimumScore = minimumScore.isFinite ? min(max(minimumScore, 0), 1) : 0.7
        self.minimumMargin = minimumMargin.isFinite ? min(max(minimumMargin, 0), 1) : 0.15
        self.requiredObservations = max(1, requiredObservations)
        self.maximumGap = maximumGap.isFinite ? max(0, maximumGap) : 2
    }
}

/// Short, ordered confirmation window. No identities/names are persisted here.
public struct TemporalConfirmation: Sendable {
    public let requiredObservations: Int
    public let maximumGap: TimeInterval
    private var target: UUID?
    private var previousTimestamp: TimeInterval?
    private var count = 0

    public init(requiredObservations: Int = 3, maximumGap: TimeInterval = 2) {
        self.requiredObservations = max(1, requiredObservations)
        self.maximumGap = maximumGap.isFinite ? max(0, maximumGap) : 2
    }
    public mutating func reset() { target = nil; previousTimestamp = nil; count = 0 }
    public mutating func observe(targetID: UUID, timestamp: TimeInterval, accepted: Bool) -> Bool {
        guard timestamp.isFinite else { reset(); return false }
        if target != targetID { reset(); target = targetID }
        if let previousTimestamp, timestamp <= previousTimestamp { return false }
        if let previousTimestamp, timestamp - previousTimestamp > maximumGap { count = 0 }
        previousTimestamp = timestamp
        guard accepted else { count = 0; return false }
        count += 1
        return count >= requiredObservations
    }
}

/// Mean of the last `window` per-frame confidences so the value does not flicker
/// frame to frame. A gap longer than `maximumGap` starts over.
public struct MatchConfidenceSmoother: Sendable {
    public let window: Int
    public let maximumGap: TimeInterval
    private var samples: [Float] = []
    private var previousTimestamp: TimeInterval?

    public init(window: Int = 3, maximumGap: TimeInterval = 2) {
        self.window = max(1, window)
        self.maximumGap = maximumGap.isFinite ? max(0, maximumGap) : 2
    }
    public mutating func reset() { samples.removeAll(); previousTimestamp = nil }
    public mutating func add(_ confidence: Float, at timestamp: TimeInterval) -> Float {
        guard timestamp.isFinite, confidence.isFinite else { reset(); return 0 }
        if let previousTimestamp, timestamp - previousTimestamp > maximumGap { samples.removeAll() }
        previousTimestamp = timestamp
        samples.append(min(max(confidence, 0), 1))
        if samples.count > window { samples.removeFirst(samples.count - window) }
        return samples.reduce(0, +) / Float(samples.count)
    }
}
