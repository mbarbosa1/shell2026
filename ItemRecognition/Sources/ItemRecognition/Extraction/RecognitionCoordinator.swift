import CoreGraphics
import Foundation

public struct RecognitionUpdate: Sendable {
    public let gate: ActivationDecision
    public let observation: ProductTextObservation?
    public let result: ItemRecognitionResult?
    public var visualObservation: VisualObservation? { result?.visualEvidence }
    public let side: ShelfSide?
    public let guidance: RecognitionGuidance?
    /// Source of this evidence; the frame deciding a switch is still OCR.
    public let modeNotice: RecognitionModeNotice
    public let activeMode: RecognitionModeNotice
    /// Retained after switching. Consumers deduplicate its ID.
    public let pathTransition: RecognitionPathTransition?
    public let assessment: FrameAssessment?
    /// Original-buffer pixels of the object whose text matched the target when
    /// several objects were in view. Nil with one object or before a match.
    public let focusedObject: CGRect?
    /// OCR frames only: what was read and how close it came, in plain language,
    /// e.g. `Read “Reduced Fat Milk”. Partly matches (35%).` Nil when nothing was
    /// read or while the shopper is being asked.
    public let progress: String?
    public let textReadiness: LabelRegionDetection.Readiness?
    public let didRunOCR: Bool
    public let awaitingVerdict: Bool
    public let insight: String?
    /// Set once the one-minute scan deadline has passed. The shopper should leave this item.
    public let advanceNotice: String?
    /// Machine suggestions awaiting a verdict are never final item-found events.
    public var confirmedObservation: ItemObservation? {
        guard !awaitingVerdict else { return nil }
        return suggestedObservation
    }
    public var suggestedObservation: ItemObservation? {
        guard let result, result.status == .confirmed, let itemID = result.matchedItemID else { return nil }
        return ItemObservation(timestamp: result.timestamp, itemID: itemID, matchConfidence: result.matchConfidence,
            observedTerms: result.normalizedObservedText, side: side ?? observation?.side,
            evidenceSource: result.evidenceSource, visualEvidence: result.visualEvidence)
    }
    public init(gate: ActivationDecision, observation: ProductTextObservation?, result: ItemRecognitionResult?,
                side: ShelfSide? = nil, guidance: RecognitionGuidance? = nil, modeNotice: RecognitionModeNotice,
                awaitingVerdict: Bool = false, insight: String? = nil, activeMode: RecognitionModeNotice? = nil,
                pathTransition: RecognitionPathTransition? = nil, assessment: FrameAssessment? = nil,
                textReadiness: LabelRegionDetection.Readiness? = nil, didRunOCR: Bool = false,
                advanceNotice: String? = nil, focusedObject: CGRect? = nil, progress: String? = nil) {
        self.gate = gate; self.observation = observation; self.result = result; self.side = side
        self.guidance = awaitingVerdict ? nil : guidance; self.modeNotice = modeNotice
        self.awaitingVerdict = awaitingVerdict; self.insight = insight
        self.activeMode = activeMode ?? modeNotice; self.pathTransition = pathTransition
        self.assessment = assessment; self.textReadiness = textReadiness; self.didRunOCR = didRunOCR
        self.advanceNotice = advanceNotice; self.focusedObject = focusedObject
        self.progress = awaitingVerdict ? nil : progress
    }
}

/// One target/catalog snapshot per session. Every session starts with text.
/// Only mapped products can adopt their validated appearance classifier.
public actor RecognitionCoordinator {
    public nonisolated let sessionID = UUID()
    private let targetID: UUID
    private let gate: ActivationGate
    private let extraction: RecognitionFrameScheduler
    private let candidates: [CatalogItemSnapshot]
    private let wordIndex: ShelfWordIndex
    private let matcher = CatalogMatcher()
    private let policy: RecognitionPolicy
    private let visualPolicy: VisualRecognitionPolicy
    private let visualModel: VisualModelInfo?
    private let fallback: (any VisualClassifying)?
    private let routingPolicy: RecognitionRoutingPolicy
    private let targetName: String
    private var trial = TextTrial()
    private var deadline: ScanDeadline?
    private var activeMode: RecognitionModeNotice = .ocrOnly
    private var transition: RecognitionPathTransition?
    private var settled: RecognitionUpdate?
    private var visualModelVersion: String?
    private var confirmation: TemporalConfirmation
    private var smoother: MatchConfidenceSmoother
    /// Normalized box of the object last matched or read, to spot a jump to another item.
    private var lastFocus: CGRect?
    private var generation: UInt = 0
    private var busy = false
    private var stopped = false

    public init(targetID: UUID, catalog: any CatalogReading,
                recognizer: any TextRecognizing = VisionTextRecognizer(),
                detector: any LabelRegionDetecting = VisionLabelRegionDetector(),
                policy: RecognitionPolicy = RecognitionPolicy(),
                visualClassifier: (any VisualClassifying)? = nil,
                visualPolicy: VisualRecognitionPolicy = VisualRecognitionPolicy(),
                ocrFallback: (any VisualClassifying)? = nil,
                routingPolicy: RecognitionRoutingPolicy = RecognitionRoutingPolicy(),
                assessor: (any FrameAssessing)? = VisionFrameAssessor()) async throws {
        self.targetID = targetID; self.policy = policy; self.visualPolicy = visualPolicy
        self.routingPolicy = routingPolicy
        candidates = try await catalog.catalogCandidates(for: targetID)
        wordIndex = ShelfWordIndex(candidates: candidates)
        guard let target = candidates.first(where: { $0.id == targetID }) else { throw RecognitionSessionError.missingTarget }
        targetName = target.displayName
        // An explicit item type decides. Fruit and vegetables use Apple Vision;
        // any other type stays on OCR. Snapshots with no type keep the mapped path.
        let wantsAppearance = target.itemType == nil ? target.visual != nil : target.recognizesByAppearance
        if wantsAppearance, let metadata = target.visual {
            guard let classifier = visualClassifier ?? ocrFallback else { throw VisualRecognitionError.missingClassifier }
            let info = try await classifier.modelInfo()
            guard metadata.modelID == info.id else { throw VisualRecognitionError.incompatibleModel }
            guard !metadata.classIDs.isEmpty, metadata.classIDs.isSubset(of: info.supportedClassIDs) else {
                throw VisualRecognitionError.unsupportedClasses
            }
            visualModel = info; fallback = classifier
            activeMode = .appleVision
        } else {
            visualModel = nil; fallback = nil
        }
        let observations = activeMode == .appleVision ? visualPolicy.requiredObservations : policy.requiredObservations
        let gap = activeMode == .appleVision ? visualPolicy.maximumGap : policy.maximumGap
        confirmation = TemporalConfirmation(requiredObservations: observations, maximumGap: gap)
        smoother = MatchConfidenceSmoother(window: observations, maximumGap: gap)
        let gate = ActivationGate(catalog: catalog)
        self.gate = gate
        extraction = RecognitionFrameScheduler(gate: gate, recognizer: recognizer, regionDetector: detector, assessor: assessor)
        if activeMode == .appleVision, let classifier = fallback {
            await extraction.switchToVisual(classifier)
        }
    }

    public func updateContext(_ context: RecognitionContext) async throws -> ActivationDecision {
        guard context.targetItemID == targetID else { throw RecognitionSessionError.wrongTarget }
        let decision = try await gate.evaluate(context)
        if decision.clearTemporalCandidates {
            generation &+= 1; resetEvidence(); trial.reset(); settled = nil
            await extraction.invalidate()
        }
        return decision
    }

    public func stop() async {
        stopped = true; generation &+= 1; resetEvidence(); trial.reset(); settled = nil
        await extraction.invalidate()
    }

    /// Returns final output once, only after shopper acceptance. A caller retrying
    /// persistence retains this receipt instead of accepting the same scan again.
    @discardableResult
    public func acceptInsight() async -> ItemObservation? {
        guard !stopped, let settled, settled.awaitingVerdict,
              let accepted = settled.suggestedObservation, accepted.itemID == targetID else { return nil }
        self.settled = nil; stopped = true; generation &+= 1
        await extraction.invalidate()
        return accepted
    }

    public func rejectInsight() { settled = nil; resetEvidence(); trial.reset() }
    private func resetEvidence() { confirmation.reset(); smoother.reset(); lastFocus = nil }

    public func submit(_ context: RecognitionContext, image: RecognitionImage, crop: CGRect? = nil) async throws -> RecognitionUpdate {
        guard !stopped else { throw RecognitionSessionError.stopped }
        try RecognitionFrameScheduler.validate(image, crop: crop)
        let decision = try await updateContext(context)
        guard decision.isDetectionActive else { return update(decision, result: emptyResult(image, status: .disabled)) }
        if deadline == nil { deadline = ScanDeadline(startedAt: image.timestamp) }
        let expired = deadline?.hasExpired(at: image.timestamp) == true
        if let settled { return expired ? notingDeadline(settled) : settled }
        if expired { return update(decision, advanceNotice: ScanDeadline.expiredMessage) }
        guard !busy else { return update(decision) }
        busy = true
        defer { busy = false }
        let revision = generation
        let outcome: RecognitionFrameOutcome
        do { outcome = try await extraction.submit(context, image: image, crop: crop) }
        catch { resetEvidence(); trial.reset(); throw error }
        guard await gate.currentState == .active, revision == generation, !stopped, !Task.isCancelled else {
            return update(await gate.lastDecision ?? decision)
        }
        guard case .processed(let evidence) = outcome else { return update(decision) }
        switch evidence {
        case .unsuitable(let assessment):
            resetEvidence(); trial.reset()
            return update(decision, result: emptyResult(image), guidance: assessment.guidance, assessment: assessment)
        case .visual(let visual, let assessment):
            if assessment?.continuityLost == true { resetEvidence() }
            let side = await gate.loadedRule?.side
            guard revision == generation, !stopped else { return update(decision) }
            do {
                return try matchVisual(visual, image: image,
                    expectedRegion: crop ?? assessment?.objectRegion ?? CGRect(origin: .zero, size: image.imageResolution),
                    decision: decision, side: side, assessment: assessment)
            } catch { resetEvidence(); throw error }
        case .text(let observation, let detection, let assessment):
            if assessment?.continuityLost == true { resetEvidence(); trial.reset() }
            let hasText = observation?.candidates.isEmpty == false
            let suitable = detection.readiness == .noText || detection.readiness == .readable
            // Several objects: each object's text is scored alone and the catalog picks
            // the target's box, so water beside the milk never mixes into its evidence.
            let objects = assessment?.objectBoxes ?? []
            let separate = objects.count > 1
            var read = observation
            var focus: CGRect?
            let matches: [CatalogMatch]
            if separate, let observation {
                let picked = matcher.matchPerObject(observation, objectBoxes: objects, against: candidates,
                    requireDiscriminatingTerms: policy.requireDiscriminatingTerms, targetID: targetID, index: wordIndex)
                matches = picked?.matches ?? []
                read = picked?.observation ?? observation
                focus = picked?.objectBox
            } else {
                matches = observation.map { matcher.match($0, against: candidates, requireDiscriminatingTerms: policy.requireDiscriminatingTerms,
                    targetID: targetID, index: wordIndex) } ?? []
                focus = objects.first
            }
            // Evidence only chains while the chosen box stays put; a jump means another object.
            if separate, let focus, let last = lastFocus, VisionFrameAssessor.overlap(last, focus) < 0.15 { resetEvidence() }
            if let focus { lastFocus = focus }
            let target = matches.first { $0.itemID == targetID }
            let score = target?.score ?? 0
            let runnerUp = matches.filter { $0.itemID != targetID }.map(\.score).max() ?? 0
            let accepted = score > 0 && score >= policy.minimumScore && score - runnerUp >= policy.minimumMargin && target?.conflicts.isEmpty == true
            let confirmed = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: accepted)
            let strength = policy.minimumScore > 0 ? min(score / policy.minimumScore, 1) : 1
            let confidence = smoother.add(score > 0 ? score / (score + runnerUp) * strength : 0, at: image.timestamp)
            let terms = Set(read?.candidates.flatMap { TextNormalizer().tokens(from: $0.normalizedText) } ?? [])
            let result = ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
                matchedItemID: confirmed ? targetID : nil, normalizedObservedText: terms, score: score,
                status: confirmed ? .confirmed : (score > 0 ? .candidate : .noMatch), matchConfidence: confidence)
            if let reason = trial.observe(at: image.timestamp, suitable: suitable, hasText: hasText,
                usefulMatch: accepted, policy: routingPolicy), let fallback {
                transition = RecognitionPathTransition(id: UUID(), timestamp: image.timestamp,
                    reason: reason, suitableAttempts: trial.suitableAttempts)
                activeMode = .appleVision
                confirmation = TemporalConfirmation(requiredObservations: visualPolicy.requiredObservations, maximumGap: visualPolicy.maximumGap)
                smoother = MatchConfidenceSmoother(window: visualPolicy.requiredObservations, maximumGap: visualPolicy.maximumGap)
                await extraction.switchToVisual(fallback)
                guard revision == generation, !stopped else { return update(decision) }
            }
            // Size advice from the assessor only stands when OCR could not read anything.
            let sizeAdvice = assessment?.quality == .tooSmall || assessment?.quality == .clipped
            let assessorGuidance = sizeAdvice && hasText ? nil : assessment?.guidance
            var guidance = assessorGuidance ?? detection.guidance ??
                (detection.readiness == .noText && fallback == nil ? .showLabel : nil)
            if separate {
                // Steer toward the matched object; before a match, left/right would be a guess.
                if let focus { guidance = VisionLabelRegionDetector.horizontalGuidance(for: focus) }
                else if guidance == .moveLeft || guidance == .moveRight { guidance = nil }
            }
            let focusedObject = separate ? focus.flatMap { try? VisionRegionOfInterest.pixelCrop(normalizedRegion: $0,
                imageSize: image.imageResolution, orientation: image.orientation) } : nil
            let text = read?.candidates.map(\.rawText).joined(separator: " ")
            let value = update(decision, observation: read, result: result, guidance: guidance,
                source: .ocrOnly, assessment: assessment, readiness: detection.readiness, didRunOCR: observation != nil,
                awaitingVerdict: confirmed, insight: confirmed ? targetName : text, focusedObject: focusedObject,
                progress: Self.progress(read: text, score: score, accepted: accepted, confidence: confidence))
            if confirmed { settled = value }
            return value
        }
    }

    private func update(_ gate: ActivationDecision, observation: ProductTextObservation? = nil,
                        result: ItemRecognitionResult? = nil, side: ShelfSide? = nil,
                        guidance: RecognitionGuidance? = nil, source: RecognitionModeNotice? = nil,
                        assessment: FrameAssessment? = nil, readiness: LabelRegionDetection.Readiness? = nil,
                        didRunOCR: Bool = false, awaitingVerdict: Bool = false, insight: String? = nil,
                        advanceNotice: String? = nil, focusedObject: CGRect? = nil,
                        progress: String? = nil) -> RecognitionUpdate {
        RecognitionUpdate(gate: gate, observation: observation, result: result, side: side,
            guidance: guidance, modeNotice: source ?? activeMode, awaitingVerdict: awaitingVerdict, insight: insight,
            activeMode: activeMode, pathTransition: transition, assessment: assessment,
            textReadiness: readiness, didRunOCR: didRunOCR, advanceNotice: advanceNotice, focusedObject: focusedObject,
            progress: progress)
    }
    /// Longest read-back quoted in a progress line, so a spoken answer stays short.
    static let progressQuoteLength = 40

    /// What OCR read and how close it came to the target. `confidence` is the
    /// match confidence shown elsewhere, so the percentage agrees with the screen.
    static func progress(read: String?, score: Float, accepted: Bool, confidence: Float) -> String? {
        guard let read = read?.trimmingCharacters(in: .whitespacesAndNewlines), !read.isEmpty else { return nil }
        let quoted = read.count > progressQuoteLength ? String(read.prefix(progressQuoteLength - 1)) + "…" : read
        let percent = Int((confidence * 100).rounded())
        if accepted { return "Read “\(quoted)”. Matches (\(percent)%). Hold still." }
        if score > 0 { return "Read “\(quoted)”. Partly matches (\(percent)%)." }
        return "Read “\(quoted)”. Not the item yet."
    }

    private func notingDeadline(_ update: RecognitionUpdate) -> RecognitionUpdate {
        RecognitionUpdate(gate: update.gate, observation: update.observation, result: update.result, side: update.side,
            guidance: update.guidance, modeNotice: update.modeNotice, awaitingVerdict: update.awaitingVerdict,
            insight: update.insight, activeMode: update.activeMode, pathTransition: update.pathTransition,
            assessment: update.assessment, textReadiness: update.textReadiness, didRunOCR: update.didRunOCR,
            advanceNotice: ScanDeadline.expiredMessage, focusedObject: update.focusedObject, progress: update.progress)
    }
    private func emptyResult(_ image: RecognitionImage, status: ItemRecognitionResult.Status = .noMatch) -> ItemRecognitionResult {
        ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID, matchedItemID: nil,
            normalizedObservedText: [], score: 0, status: status, evidenceSource: activeMode == .ocrOnly ? .ocr : .visual)
    }
    private func matchVisual(_ observation: VisualObservation, image: RecognitionImage,
                             expectedRegion: CGRect, decision: ActivationDecision, side: ShelfSide?,
                             assessment: FrameAssessment?) throws -> RecognitionUpdate {
        guard let visualModel, observation.modelID == visualModel.id, !observation.modelVersion.isEmpty,
              observation.timestamp.isFinite, observation.timestamp == image.timestamp, observation.inputRegion == expectedRegion,
              observation.classifications.allSatisfy({ visualModel.supportedClassIDs.contains($0.identifier) }) else {
            throw VisualRecognitionError.invalidObservation
        }
        try VisionRegionOfInterest.validate(pixelCrop: observation.inputRegion, imageSize: image.imageResolution)
        if visualModelVersion != observation.modelVersion { resetEvidence(); visualModelVersion = observation.modelVersion }
        let match = try VisualCatalogMatcher().match(observation, targetID: targetID, against: candidates, policy: visualPolicy)
        let confirmed = confirmation.observe(targetID: targetID, timestamp: image.timestamp, accepted: match.accepted)
        let confidence = smoother.add(match.confidence, at: image.timestamp)
        let result = ItemRecognitionResult(timestamp: image.timestamp, targetItemID: targetID,
            matchedItemID: confirmed ? targetID : nil, normalizedObservedText: [], score: match.score,
            status: confirmed ? .confirmed : (match.score >= visualPolicy.minimumScore && match.score > 0 ? .candidate : .noMatch),
            matchConfidence: confidence, evidenceSource: .visual, visualEvidence: observation, visualMatchReason: match.reason)
        let value = update(decision, result: result, side: side, guidance: assessment?.guidance,
            source: observation.kind == .cloudSuggestion ? .cloudAssist : .appleVision,
            assessment: assessment, awaitingVerdict: confirmed, insight: confirmed ? targetName : match.classID)
        if confirmed { settled = value }
        return value
    }
}

public enum RecognitionSessionError: Error { case missingTarget, wrongTarget, stopped }
