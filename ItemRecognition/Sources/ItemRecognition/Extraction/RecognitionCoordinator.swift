import CoreGraphics
import Foundation

public struct RecognitionUpdate: Sendable {
    public let gate: ActivationDecision
    public let observation: ProductTextObservation?
    public let result: ItemRecognitionResult?
    public var visualObservation: VisualObservation? { result?.visualEvidence }
    public let side: ShelfSide?
    /// Plain-language direction for the user from this frame's detection
    /// ("Move closer to the item"). Nil when the item is framed well enough.
    public let guidance: RecognitionGuidance?
    /// Which recognizer produced this update. `.cloudAssist` only when the
    /// evidence itself came back from Gemini; on-device frames between cloud
    /// calls report `.appleVision`.
    public let modeNotice: RecognitionModeNotice
    /// True once a path has confidently finished and is waiting for the user
    /// to confirm or reject the insight. Further frames repeat this update.
    public let awaitingVerdict: Bool
    /// The words OCR read, or the object Apple Vision or Gemini named.
    public let insight: String?
    public var confirmedObservation: ItemObservation? {
        guard let result, result.status == .confirmed, let itemID = result.matchedItemID else { return nil }
        return ItemObservation(timestamp: result.timestamp, itemID: itemID, matchConfidence: result.matchConfidence,
                               observedTerms: result.normalizedObservedText, side: side ?? observation?.side,
                               evidenceSource: result.evidenceSource, visualEvidence: result.visualEvidence)
    }
    public init(gate: ActivationDecision, observation: ProductTextObservation?,
                result: ItemRecognitionResult?, side: ShelfSide? = nil,
                guidance: RecognitionGuidance? = nil, modeNotice: RecognitionModeNotice,
                awaitingVerdict: Bool = false, insight: String? = nil) {
        self.gate = gate; self.observation = observation; self.result = result; self.side = side
        self.guidance = guidance; self.modeNotice = modeNotice
        self.awaitingVerdict = awaitingVerdict; self.insight = insight
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
    private var visualPolicy: VisualRecognitionPolicy
    private let visualModel: VisualModelInfo?
    /// Image classifier used only after OCR produces no text three times.
    private let ocrFallback: (any VisualClassifying)?
    private var emptyOCRFrames = 0
    private var deviatedFromOCR = false
    private var settled: RecognitionUpdate?
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
                visualPolicy: VisualRecognitionPolicy = VisualRecognitionPolicy(),
                ocrFallback: (any VisualClassifying)? = nil) async throws {
        self.targetID = targetID
        self.policy = policy
        self.visualPolicy = visualPolicy
        self.ocrFallback = ocrFallback
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
        settled = nil
        await extraction.invalidate()
    }

    /// The user accepted the settled insight. Scanning does not resume.
    public func acceptInsight() async {
        stopped = true
        generation &+= 1
        await extraction.invalidate()
    }

    /// The user rejected the settled insight. The same path keeps looking.
    public func rejectInsight() {
        settled = nil
        resetEvidence()
    }

    private func resetEvidence() { confirmation.reset(); smoother.reset() }

    public func submit(_ context: RecognitionContext, image: RecognitionImage, crop: CGRect? = nil) async throws -> RecognitionUpdate {
        guard !stopped else { throw RecognitionSessionError.stopped }
        if let settled { return settled }
        try TextExtractionScheduler.validate(image, crop: crop)
        let decision = try await updateContext(context)
        guard decision.isDetectionActive else {
            return RecognitionUpdate(gate: decision, observation: nil, result: result(image, status: .disabled),
                                     modeNotice: sessionNotice)
        }
        guard !busy else { return RecognitionUpdate(gate: decision, observation: nil, result: nil, modeNotice: sessionNotice) }
        busy = true
        defer { busy = false }
        let revision = generation
        let outcome: RecognitionFrameOutcome
        do { outcome = try await extraction.submit(context, image: image, crop: crop) }
        catch { resetEvidence(); throw error }
        let currentState = await gate.currentState
        guard currentState == .active, revision == generation, !stopped else {
            return RecognitionUpdate(gate: await gate.lastDecision ?? decision, observation: nil, result: nil,
                                     modeNotice: sessionNotice)
        }
        guard case .processed(let evidence) = outcome else {
            return RecognitionUpdate(gate: decision, observation: nil, result: nil, modeNotice: sessionNotice)
        }
        if case .visual(let visual) = evidence {
            let side = await gate.loadedRule?.side
            guard revision == generation, !stopped else {
                return RecognitionUpdate(gate: decision, observation: nil, result: nil, modeNotice: sessionNotice)
            }
            do {
                if visualModel == nil {
                    return finishDeviated(visual, image: image, decision: decision, side: side)
                }
                return try matchVisual(visual, image: image, expectedRegion: crop ?? CGRect(origin: .zero, size: image.imageResolution),
                                       decision: decision, side: side)
            } catch { resetEvidence(); throw error }
        }
        guard case .text(let observation, let guidance) = evidence else {
            return RecognitionUpdate(gate: decision, observation: nil, result: nil, modeNotice: sessionNotice)
        }
        guard let observation else {
            _ = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: false)
            let confidence = smoother.add(0, at: image.timestamp)
            await noteEmptyOCR()
            return RecognitionUpdate(gate: decision, observation: nil,
                                     result: result(image, status: .noMatch, matchConfidence: confidence),
                                     guidance: guidance, modeNotice: .ocrOnly)
        }
        guard !observation.candidates.isEmpty else {
            _ = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: false)
            let confidence = smoother.add(0, at: image.timestamp)
            await noteEmptyOCR()
            return RecognitionUpdate(gate: decision, observation: observation,
                                     result: result(image, status: .noMatch, matchConfidence: confidence),
                                     guidance: guidance, modeNotice: .ocrOnly)
        }
        emptyOCRFrames = 0
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
        let insight = observation.candidates.map(\.rawText).joined(separator: " ")
        return settle(RecognitionUpdate(gate: decision, observation: observation,
            result: ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed ? targetID : nil, normalizedObservedText: terms, score: score, status: status,
                matchConfidence: confidence),
            guidance: guidance, modeNotice: .ocrOnly), insight: insight)
    }

    /// Three processed frames with no text is a definite miss, not a blurry one.
    /// The next frames use the image classifier. "Move closer" is the guidance
    /// on those empty frames; it is not a separate counter.
    private func noteEmptyOCR() async {
        emptyOCRFrames += 1
        guard emptyOCRFrames >= 3, !deviatedFromOCR, let ocrFallback else { return }
        deviatedFromOCR = true
        visualPolicy = .appleVisionProduce
        confirmation = TemporalConfirmation(requiredObservations: visualPolicy.requiredObservations,
                                            maximumGap: visualPolicy.maximumGap)
        smoother = MatchConfidenceSmoother(window: visualPolicy.requiredObservations, maximumGap: visualPolicy.maximumGap)
        await extraction.switchToVisual(ocrFallback)
    }

    /// Image recognition adopted after OCR failed. Returns the object in view
    /// for the user to confirm. It does not attach that label to the selected
    /// catalog product unless the product is mapped to the same class.
    private func finishDeviated(_ observation: VisualObservation, image: RecognitionImage,
                                decision: ActivationDecision, side: ShelfSide?) -> RecognitionUpdate {
        let produce = observation.classifications.filter { $0.identifier != "unknown" }.sorted { $0.score > $1.score }
        let top = produce.first
        let runnerUp = produce.dropFirst().first?.score ?? 0
        let score = top?.score ?? 0
        let accepted = score >= visualPolicy.minimumScore && score - runnerUp >= visualPolicy.minimumMargin
        let confirmed = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: accepted)
        let confidence = smoother.add(accepted ? min(score, 1) : 0, at: image.timestamp)
        let mapped = candidates.first { $0.id == targetID }?.visual?.classIDs.contains(top?.identifier ?? "") == true
        let status: ItemRecognitionResult.Status = confirmed ? .confirmed :
            (score > 0 ? .candidate : .noMatch)
        return settle(RecognitionUpdate(gate: decision, observation: nil,
            result: ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed && mapped ? targetID : nil, normalizedObservedText: [],
                score: score, status: status, matchConfidence: confidence, evidenceSource: .visual,
                visualEvidence: observation,
                visualMatchReason: accepted ? .acceptedCategory : .insufficientEvidence),
            side: side,
            modeNotice: observation.kind == .cloudSuggestion ? .cloudAssist : .appleVision),
            insight: top?.identifier)
    }

    private func settle(_ update: RecognitionUpdate, insight: String?) -> RecognitionUpdate {
        guard update.result?.status == .confirmed else { return update }
        let verdict = RecognitionUpdate(gate: update.gate, observation: update.observation, result: update.result,
                                        side: update.side, guidance: nil, modeNotice: update.modeNotice,
                                        awaitingVerdict: true, insight: insight)
        settled = verdict
        return verdict
    }

    /// Notice for updates that carry no evidence: the session's current path.
    private var sessionNotice: RecognitionModeNotice {
        if visualModel == nil && !deviatedFromOCR { return .ocrOnly }
        return .appleVision
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
        return settle(RecognitionUpdate(gate: decision, observation: nil,
            result: ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed ? targetID : nil, normalizedObservedText: [], score: match.score,
                status: status, matchConfidence: confidence, evidenceSource: .visual,
                visualEvidence: observation, visualMatchReason: match.reason),
            side: side,
            modeNotice: observation.kind == .cloudSuggestion ? .cloudAssist : .appleVision),
            insight: observation.classifications.max { $0.score < $1.score }?.identifier)
    }
}

public enum RecognitionSessionError: Error { case missingTarget, wrongTarget, stopped }
