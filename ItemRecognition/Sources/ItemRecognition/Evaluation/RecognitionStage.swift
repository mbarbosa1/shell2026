import Foundation

/// Where one processed frame stopped on its way to a shopper question, in pipeline
/// order. A baseline attributes each failed scan to these stages instead of to
/// "recognition" in general, because each stage needs a different fix.
public enum RecognitionStage: Int, Sendable, Codable, CaseIterable, Comparable {
    /// The gate kept recognition off: position, pause, missing rule, not in store.
    case activation
    /// No steady, focused object: not located, refocusing, or moving.
    case localization
    /// An object was found but gave no usable region: too small, clipped, or no
    /// legible text region on the package.
    case cropping
    /// A region was read but OCR returned no words, or the target's class missed
    /// the model's score or lead over other labels.
    case ocrOrClassification
    /// Words or a label came back but did not single out the target: a neighbor
    /// led, too few title words, a conflicting word, or a catalog ambiguity.
    case matching
    /// This frame passed; the policy wants more frames before asking.
    case confirming
    /// The shopper is being asked. Only their answer counts as success.
    case awaitingShopper

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .activation: return "activation"
        case .localization: return "localization"
        case .cropping: return "cropping"
        case .ocrOrClassification: return "ocr/classification"
        case .matching: return "matching"
        case .confirming: return "confirming"
        case .awaitingShopper: return "awaiting shopper"
        }
    }

    /// Stages that end a frame without progress. `confirming` and `awaitingShopper` do not.
    public var isFailure: Bool { self < .confirming }
}

public struct RecognitionStageOutcome: Sendable, Equatable, Codable {
    public let stage: RecognitionStage
    /// The specific cause within the stage, e.g. `focusing`, `textTooSmall`, `neighborLeads`.
    public let reason: String
    public init(_ stage: RecognitionStage, _ reason: String) { self.stage = stage; self.reason = reason }
}

public extension RecognitionUpdate {
    /// Nil for updates that carry no evidence: cadence-skipped, busy, discarded, or deadline-only.
    var stageOutcome: RecognitionStageOutcome? {
        if awaitingVerdict { return RecognitionStageOutcome(.awaitingShopper, result?.matchLevel?.rawValue ?? "product") }
        guard let result else { return nil }
        if !gate.isDetectionActive || result.status == .disabled {
            return RecognitionStageOutcome(.activation, gate.inactiveReason?.code ?? "\(gate.state)")
        }
        if result.visualEvidence != nil {
            if result.passesPolicy { return RecognitionStageOutcome(.confirming, "needsMoreFrames") }
            if let reason = result.visualMatchReason, reason == .categoryOnly || reason == .ambiguousCatalog {
                return RecognitionStageOutcome(.matching, reason.rawValue)
            }
            let seen = result.matchedCategory != nil && result.score > 0
            return RecognitionStageOutcome(.ocrOrClassification, seen ? "belowScoreOrLead" : "targetClassAbsent")
        }
        guard let readiness = textReadiness else {
            // No text step ran: the assessor rejected the frame before any read or classification.
            guard let quality = assessment?.quality, quality != .usable else { return nil }
            switch quality {
            case .tooSmall, .clipped: return RecognitionStageOutcome(.cropping, quality.rawValue)
            default: return RecognitionStageOutcome(.localization, quality.rawValue)
            }
        }
        guard didRunOCR else { return RecognitionStageOutcome(.cropping, readiness.rawValue) }
        guard observation?.candidates.isEmpty == false else { return RecognitionStageOutcome(.ocrOrClassification, "noWordsRead") }
        if result.passesPolicy { return RecognitionStageOutcome(.confirming, "needsMoreFrames") }
        if let leader = result.leadingItemID, leader != result.targetItemID {
            return RecognitionStageOutcome(.matching, "neighborLeads")
        }
        return RecognitionStageOutcome(.matching, result.score > 0 ? "partialTitle" : "noTargetWords")
    }
}

public extension ActivationInactiveReason {
    /// Stable name without associated values, for logs and CSV columns.
    var code: String {
        switch self {
        case .externalPause: return "externalPause"
        case .missingActivationRule: return "missingActivationRule"
        case .missingLandmark: return "missingLandmark"
        case .missingProgress: return "missingProgress"
        case .invalidProgress: return "invalidProgress"
        case .invalidActivationRule: return "invalidActivationRule"
        case .landmarkMismatch: return "landmarkMismatch"
        case .unreliableProgress: return "unreliableProgress"
        case .pastDeactivationThreshold: return "pastDeactivationThreshold"
        case .beforeActivationThreshold: return "beforeActivationThreshold"
        case .itemNotInStore: return "itemNotInStore"
        }
    }
}

/// Stage counts for one scan attempt, so a failed attempt names where its frames stopped.
public struct RecognitionStageTally: Sendable, Equatable {
    public private(set) var frames = 0
    public private(set) var stageCounts: [RecognitionStage: Int] = [:]
    /// Keyed `stage/reason`, e.g. `cropping/textTooSmall`.
    public private(set) var reasonCounts: [String: Int] = [:]
    /// The latest stage any frame reached.
    public private(set) var furthest: RecognitionStage?

    public init() {}

    public mutating func record(_ outcome: RecognitionStageOutcome) {
        frames += 1
        stageCounts[outcome.stage, default: 0] += 1
        reasonCounts["\(outcome.stage.name)/\(outcome.reason)", default: 0] += 1
        furthest = max(furthest ?? outcome.stage, outcome.stage)
    }

    /// The failure stage most frames stopped at; ties go to the earlier stage,
    /// since a later stage cannot be judged while an earlier one keeps failing.
    public var blocker: RecognitionStage? {
        var best: (stage: RecognitionStage, count: Int)?
        for stage in RecognitionStage.allCases where stage.isFailure {
            guard let count = stageCounts[stage], count > (best?.count ?? 0) else { continue }
            best = (stage, count)
        }
        return best?.stage
    }

    /// Most frequent `stage/reason` keys, highest first; ties in name order.
    public func topReasons(_ limit: Int) -> [(reason: String, count: Int)] {
        reasonCounts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(max(0, limit)).map { ($0.key, $0.value) }
    }
}
