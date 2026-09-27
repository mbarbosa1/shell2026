import CoreGraphics
import CoreVideo
import Foundation

enum RecognitionFrameEvidence: Sendable {
    /// OCR result (nil when no region was read) plus any user-facing direction
    /// from detection. Guidance survives a nil observation so "text too small"
    /// still reaches the app as "move closer".
    case text(ProductTextObservation?, detection: LabelRegionDetection, assessment: FrameAssessment?)
    case visual(VisualObservation, assessment: FrameAssessment?)
    case unsuitable(FrameAssessment)
}

enum RecognitionFrameOutcome: Sendable {
    case skipped, discarded
    case processed(RecognitionFrameEvidence)
}

/// Shared cadence, single inference slot, latest pending frame, and generation
/// invalidation for OCR or visual classification. A session uses only one mode.
/// The caller retains each buffer unchanged until its submission returns.
actor RecognitionFrameScheduler {
    static let strideRange: ClosedRange<Int> = 5...10
    static let defaultStride = 5

    private let gate: ActivationGate
    private let recognizer: any TextRecognizing
    private let regionDetector: any LabelRegionDetecting
    private let normalizer: any TextNormalizing
    private let assessor: (any FrameAssessing)?
    /// Nil on the OCR path. Set when the session gives up on text and adopts
    /// image recognition for the rest of this scan.
    private var visualClassifier: (any VisualClassifying)?

    /// Clamped to `strideRange` at init. Immutable, so readable without hopping to the actor.
    nonisolated let frameStride: Int

    private var framesWhileActive = 0
    private var generation: UInt = 0
    private var inFlight = false
    private var pending: PendingFrame?

    init(
        gate: ActivationGate,
        recognizer: any TextRecognizing,
        normalizer: any TextNormalizing = TextNormalizer(),
        frameStride: Int = TextExtractionScheduler.defaultStride,
        regionDetector: any LabelRegionDetecting = VisionLabelRegionDetector(),
        visualClassifier: (any VisualClassifying)? = nil,
        assessor: (any FrameAssessing)? = nil
    ) {
        self.gate = gate
        self.recognizer = recognizer
        self.regionDetector = regionDetector
        self.normalizer = normalizer
        self.visualClassifier = visualClassifier
        self.assessor = assessor
        self.frameStride = min(max(frameStride, Self.strideRange.lowerBound), Self.strideRange.upperBound)
    }

    /// True while the detection/OCR pipeline owns the processing slot.
    var isRequestInFlight: Bool { inFlight }

    /// True while one eligible frame is waiting for the in-flight request.
    var hasPendingFrame: Bool { pending != nil }

    /// Frames counted since the gate last became `.active`.
    var framesSinceActivation: Int { framesWhileActive }

    /// Leave OCR for the rest of this scan. In-flight text work is discarded
    /// and the frame cadence restarts so the first visual frame is a fresh look.
    func switchToVisual(_ classifier: any VisualClassifying) {
        visualClassifier = classifier
        generation &+= 1
        framesWhileActive = 0
        discardPending()
    }

    /// Invalidate queued/in-flight results and restart cadence after a context
    /// change supplied separately from camera frames.
    func invalidate() async {
        generation &+= 1
        framesWhileActive = 0
        discardPending()
        await assessor?.reset()
    }

    /// Skips cadence frames explicitly; a completed frame may have no text.
    func submit(
        _ context: RecognitionContext,
        image: RecognitionImage,
        crop: CGRect? = nil
    ) async throws -> RecognitionFrameOutcome {
        try Self.validate(image, crop: crop)

        let decision = try await gate.evaluate(context)
        if decision.clearTemporalCandidates {
            generation &+= 1
            framesWhileActive = 0
            discardPending()
        }
        guard decision.isDetectionActive else {
            framesWhileActive = 0
            discardPending()
            return .discarded
        }

        framesWhileActive += 1
        guard framesWhileActive % frameStride == 0 else {
            return .skipped
        }

        let frame = Frame(context: context, image: image, crop: crop, generation: generation)

        if inFlight {
            return try await enqueueReplacingPending(frame)
        }

        inFlight = true
        let outcome: Result<RecognitionFrameOutcome, Error>
        do {
            outcome = .success(try await perform(frame))
        } catch {
            outcome = .failure(error)
        }
        inFlight = false
        startPendingIfAny()
        return try outcome.get()
    }

    // MARK: - Validation

    static func validate(_ image: RecognitionImage, crop: CGRect?) throws {
        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(image.pixelBuffer),
            height: CVPixelBufferGetHeight(image.pixelBuffer)
        )
        let declared = image.imageResolution

        guard bufferSize.width > 0, bufferSize.height > 0,
              declared.width > 0, declared.height > 0 else {
            throw TextExtractionError.invalidImage(.zeroDimension)
        }
        guard declared == bufferSize else {
            throw TextExtractionError.invalidImage(
                .resolutionMismatch(declared: declared, buffer: bufferSize)
            )
        }
        if let crop {
            try VisionRegionOfInterest.validate(pixelCrop: crop, imageSize: declared)
        }
    }

    // MARK: - Slot management

    private struct Frame {
        let context: RecognitionContext
        let image: RecognitionImage
        let crop: CGRect?
        let generation: UInt
    }

    private struct PendingFrame {
        let frame: Frame
        let continuation: CheckedContinuation<RecognitionFrameOutcome, Error>
    }

    private func enqueueReplacingPending(_ frame: Frame) async throws -> RecognitionFrameOutcome {
        discardPending()
        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingFrame(frame: frame, continuation: continuation)
        }
    }

    private func discardPending() {
        guard let waiting = pending else { return }
        pending = nil
        waiting.continuation.resume(returning: .discarded)
    }

    private func startPendingIfAny() {
        guard let waiting = pending else { return }
        pending = nil
        inFlight = true
        Task { await self.runPending(waiting) }
    }

    private func runPending(_ waiting: PendingFrame) async {
        let outcome: Result<RecognitionFrameOutcome, Error>
        do {
            outcome = .success(try await perform(waiting.frame))
        } catch {
            outcome = .failure(error)
        }
        inFlight = false
        waiting.continuation.resume(with: outcome)
        startPendingIfAny()
    }

    // MARK: - Inference

    private func perform(_ frame: Frame) async throws -> RecognitionFrameOutcome {
        guard await isCurrent(frame) else { return .discarded }
        let assessment = try await assessor?.assess(frame.image)
        guard await isCurrent(frame), !Task.isCancelled else { return .discarded }
        if let assessment, !assessment.isSuitable {
            // Size is only a hint for text: a small or close item may still be readable,
            // so OCR tries it and the coordinator advises only when nothing could be read.
            let sizeOnly = assessment.objectRegion != nil && (assessment.quality == .tooSmall || assessment.quality == .clipped)
            guard visualClassifier == nil, sizeOnly else { return .processed(.unsuitable(assessment)) }
        }
        if let visualClassifier {
            // Appearance classifies the whole crop, so it still needs one item in view.
            if let assessment, assessment.objectBoxes.count > 1 {
                return .processed(.unsuitable(FrameAssessment(objectRegion: nil, quality: .multipleObjects,
                    continuityLost: true, objectBoxes: assessment.objectBoxes)))
            }
            let observation = try await visualClassifier.classify(in: frame.image, crop: frame.crop ?? assessment?.objectRegion)
            guard await isCurrent(frame) else { return .discarded }
            return .processed(.visual(observation, assessment: assessment))
        }
        let crop: CGRect
        let detection: LabelRegionDetection
        if let supplied = frame.crop {
            crop = supplied
            detection = LabelRegionDetection(crop: supplied, guidance: assessment?.guidance)
        } else {
            detection = try await regionDetector.detectRegion(in: frame.image, within: assessment?.objectRegion)
            guard let detected = detection.crop else {
                guard await isCurrent(frame) else { return .discarded }
                return .processed(.text(nil, detection: detection, assessment: assessment))
            }
            crop = detected
        }
        // Do not start OCR if a pause or target change arrived during detection.
        guard await isCurrent(frame) else { return .discarded }
        let regionOfInterest = try VisionRegionOfInterest.normalized(
            pixelCrop: crop, imageSize: frame.image.imageResolution, orientation: frame.image.orientation
        )

        let lines = try await recognizer.recognizeText(
            in: frame.image,
            regionOfInterest: regionOfInterest
        )

        // Finish-then-discard: the gate may have left .active or switched
        // target while Vision was working.
        let rule = await gate.loadedRule
        guard await isCurrent(frame) else {
            return .discarded
        }

        let candidates = lines.map { line in
            RecognizedTextCandidate(
                rawText: line.text,
                normalizedText: normalizer.normalize(line.text),
                confidence: line.confidence,
                boundingBox: line.boundingBox
            )
        }

        return .processed(.text(ProductTextObservation(
            timestamp: frame.image.timestamp,
            targetItemID: frame.context.targetItemID,
            boundingBox: crop,
            candidates: candidates,
            side: rule?.side
        ), detection: detection, assessment: assessment))
    }

    private func isCurrent(_ frame: Frame) async -> Bool {
        let rule = await gate.loadedRule
        let active = await gate.currentState == .active
        return active && rule?.targetItemID == frame.context.targetItemID && frame.generation == generation
    }
}
