import CoreGraphics
import Foundation

public struct RecognitionUpdate: Sendable {
    public let gate: ActivationDecision
    public let observation: ProductTextObservation?
    public let result: ItemRecognitionResult?
    public var visualObservation: VisualObservation? { result?.visualEvidence }
    public let side: ShelfSide?
    public var confirmedObservation: ItemObservation? {
        guard let result, result.status == .confirmed, let itemID = result.matchedItemID else { return nil }
        return ItemObservation(timestamp: result.timestamp, itemID: itemID, matchConfidence: result.matchConfidence,
                               observedTerms: result.normalizedObservedText, side: side ?? observation?.side,
                               evidenceSource: result.evidenceSource, visualEvidence: result.visualEvidence)
    }
    public init(gate: ActivationDecision, observation: ProductTextObservation?,
                result: ItemRecognitionResult?, side: ShelfSide? = nil) {
        self.gate = gate; self.observation = observation; self.result = result; self.side = side
    }
}

/// One session per selected target/store/location and catalog revision. Load
/// snapshots before starting capture; recreate after an import or rule edit.
/// Only one submission can own inference. Context changes can still invalidate it.
public actor RecognitionCoordinator {
    private let targetID: UUID
    private let gate: ActivationGate
    private let extraction: RecognitionFrameScheduler
    private let candidates: [CatalogItemSnapshot]
    private let matcher = CatalogMatcher()
    private let policy: RecognitionPolicy
    private let visualPolicy: VisualRecognitionPolicy
    private let visualModel: VisualModelInfo?
    private var visualModelVersion: String?
    private var confirmation: TemporalConfirmation
    private var smoother: MatchConfidenceSmoother
    private var generation: UInt = 0
    private var busy = false
    private var stopped = false

    public init(targetID: UUID, catalog: any CatalogReading,
                recognizer: any TextRecognizing = VisionTextRecognizer(),
                detector: any LabelRegionDetecting = VisionLabelRegionDetector(),
                policy: RecognitionPolicy = RecognitionPolicy(),
                visualClassifier: (any VisualClassifying)? = nil,
                visualPolicy: VisualRecognitionPolicy = VisualRecognitionPolicy()) async throws {
        self.targetID = targetID
        self.policy = policy
        self.visualPolicy = visualPolicy
        candidates = try await catalog.catalogCandidates(for: targetID)
        guard let target = candidates.first(where: { $0.id == targetID }) else { throw RecognitionSessionError.missingTarget }
        if let metadata = target.visual {
            guard let visualClassifier else { throw VisualRecognitionError.missingClassifier }
            let info = try await visualClassifier.modelInfo()
            guard metadata.modelID == info.id else { throw VisualRecognitionError.incompatibleModel }
            guard !metadata.classIDs.isEmpty, metadata.classIDs.isSubset(of: info.supportedClassIDs) else {
                throw VisualRecognitionError.unsupportedClasses
            }
            visualModel = info
            confirmation = TemporalConfirmation(requiredObservations: visualPolicy.requiredObservations, maximumGap: visualPolicy.maximumGap)
            smoother = MatchConfidenceSmoother(window: visualPolicy.requiredObservations, maximumGap: visualPolicy.maximumGap)
        } else {
            visualModel = nil
            confirmation = TemporalConfirmation(requiredObservations: policy.requiredObservations, maximumGap: policy.maximumGap)
            smoother = MatchConfidenceSmoother(window: policy.requiredObservations, maximumGap: policy.maximumGap)
        }
        let gate = ActivationGate(catalog: catalog)
        self.gate = gate
        extraction = RecognitionFrameScheduler(gate: gate, recognizer: recognizer, regionDetector: detector,
                                               visualClassifier: target.visual == nil ? nil : visualClassifier)
    }

    /// Feed context changes even if camera delivery is paused. Call stop on target
    /// completion and construct a new coordinator when the selected target changes.
    public func updateContext(_ context: RecognitionContext) async throws -> ActivationDecision {
        guard context.targetItemID == targetID else { throw RecognitionSessionError.wrongTarget }
        let decision = try await gate.evaluate(context)
        if decision.clearTemporalCandidates {
            generation &+= 1; resetEvidence()
            await extraction.invalidate()
        }
        return decision
    }

    public func stop() async {
        stopped = true; generation &+= 1; resetEvidence()
        await extraction.invalidate()
    }

    private func resetEvidence() { confirmation.reset(); smoother.reset() }

    public func submit(_ context: RecognitionContext, image: RecognitionImage, crop: CGRect? = nil) async throws -> RecognitionUpdate {
        guard !stopped else { throw RecognitionSessionError.stopped }
        try TextExtractionScheduler.validate(image, crop: crop)
        let decision = try await updateContext(context)
        guard decision.isDetectionActive else {
            return RecognitionUpdate(gate: decision, observation: nil, result: result(image, status: .disabled))
        }
        guard !busy else { return RecognitionUpdate(gate: decision, observation: nil, result: nil) }
        busy = true
        defer { busy = false }
        let revision = generation
        let outcome: RecognitionFrameOutcome
        do { outcome = try await extraction.submit(context, image: image, crop: crop) }
        catch { resetEvidence(); throw error }
        let currentState = await gate.currentState
        guard currentState == .active, revision == generation, !stopped else {
            return RecognitionUpdate(gate: await gate.lastDecision ?? decision, observation: nil, result: nil)
        }
        guard case .processed(let evidence) = outcome else {
            return RecognitionUpdate(gate: decision, observation: nil, result: nil)
        }
        if case .visual(let visual) = evidence {
            let side = await gate.loadedRule?.side
            guard revision == generation, !stopped else {
                return RecognitionUpdate(gate: decision, observation: nil, result: nil)
            }
            do {
                return try matchVisual(visual, image: image, expectedRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
                                       decision: decision, side: side)
            } catch { resetEvidence(); throw error }
        }
        guard case .text(let observation) = evidence, let observation else {
            _ = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: false)
            let confidence = smoother.add(0, at: image.timestamp)
            return RecognitionUpdate(gate: decision, observation: nil, result: result(image, status: .noMatch, matchConfidence: confidence))
        }
        let matches = matcher.match(observation, against: candidates)
        let target = matches.first { $0.itemID == targetID }
        let score = target?.score ?? 0
        let runnerUp = matches.filter { $0.itemID != targetID }.map(\.score).max() ?? 0
        let accepted = score > 0 && score >= policy.minimumScore && score - runnerUp >= policy.minimumMargin && target?.conflicts.isEmpty == true
        let confirmed = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: accepted)
        let status: ItemRecognitionResult.Status = confirmed ? .confirmed : (score > 0 ? .candidate : .noMatch)
        // OCR: the target's share of catalog text evidence, scaled to the policy threshold.
        let strength = policy.minimumScore > 0 ? min(score / policy.minimumScore, 1) : 1
        let frameConfidence = score > 0 ? score / (score + runnerUp) * strength : 0
        let confidence = smoother.add(frameConfidence, at: image.timestamp)
        let terms = Set(observation.candidates.flatMap { TextNormalizer().tokens(from: $0.normalizedText) })
        return RecognitionUpdate(gate: decision, observation: observation,
            result: ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed ? targetID : nil, normalizedObservedText: terms, score: score, status: status,
                matchConfidence: confidence))
    }

    private func result(_ image: RecognitionImage, status: ItemRecognitionResult.Status,
                        matchConfidence: Float = 0) -> ItemRecognitionResult {
        ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID, matchedItemID: nil,
                              normalizedObservedText: [], score: 0, status: status, matchConfidence: matchConfidence,
                              evidenceSource: visualModel == nil ? .ocr : .visual)
    }

    private func matchVisual(_ observation: VisualObservation, image: RecognitionImage,
                             expectedRegion: CGRect, decision: ActivationDecision, side: ShelfSide?) throws -> RecognitionUpdate {
        guard let visualModel, observation.modelID == visualModel.id,
              !observation.modelVersion.isEmpty, observation.timestamp.isFinite,
              observation.timestamp == image.timestamp, observation.inputRegion == expectedRegion,
              observation.classifications.allSatisfy({ visualModel.supportedClassIDs.contains($0.identifier) }) else {
            throw VisualRecognitionError.invalidObservation
        }
        try VisionRegionOfInterest.validate(pixelCrop: observation.inputRegion, imageSize: image.imageResolution)
        if visualModelVersion != observation.modelVersion {
            resetEvidence()
            visualModelVersion = observation.modelVersion
        }
        let match = try VisualCatalogMatcher().match(observation, targetID: targetID,
                                                    against: candidates, policy: visualPolicy)
        let confirmed = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: match.accepted)
        let confidence = smoother.add(match.confidence, at: image.timestamp)
        let status: ItemRecognitionResult.Status = confirmed ? .confirmed :
            (match.score >= visualPolicy.minimumScore && match.score > 0 ? .candidate : .noMatch)
        return RecognitionUpdate(gate: decision, observation: nil,
            result: ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed ? targetID : nil, normalizedObservedText: [], score: match.score,
                status: status, matchConfidence: confidence, evidenceSource: .visual, visualEvidence: observation,
                visualMatchReason: match.reason),
            side: side)
    }
}

public enum RecognitionSessionError: Error { case missingTarget, wrongTarget, stopped }
