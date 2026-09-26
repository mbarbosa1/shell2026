import CoreGraphics
import CoreVideo
import Foundation

enum RecognitionFrameEvidence: Sendable {
    case text(ProductTextObservation?)
    case visual(VisualObservation)
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
    private let visualClassifier: (any VisualClassifying)?

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
        visualClassifier: (any VisualClassifying)? = nil
    ) {
        self.gate = gate
        self.recognizer = recognizer
        self.regionDetector = regionDetector
        self.normalizer = normalizer
        self.visualClassifier = visualClassifier
        self.frameStride = min(max(frameStride, Self.strideRange.lowerBound), Self.strideRange.upperBound)
    }

    /// True while the detection/OCR pipeline owns the processing slot.
    var isRequestInFlight: Bool { inFlight }

    /// True while one eligible frame is waiting for the in-flight request.
    var hasPendingFrame: Bool { pending != nil }

    /// Frames counted since the gate last became `.active`.
    var framesSinceActivation: Int { framesWhileActive }

    /// Invalidate queued/in-flight results and restart cadence after a context
    /// change supplied separately from camera frames.
    func invalidate() {
        generation &+= 1
        framesWhileActive = 0
        discardPending()
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
        if let visualClassifier {
            let observation = try await visualClassifier.classify(in: frame.image, crop: frame.crop)
            guard await isCurrent(frame) else { return .discarded }
            return .processed(.visual(observation))
        }
        let crop: CGRect
        if let supplied = frame.crop {
            crop = supplied
        } else {
            guard let detected = try await regionDetector.detectRegion(in: frame.image) else {
                guard await isCurrent(frame) else { return .discarded }
                return .processed(.text(nil))
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
        )))
    }

    private func isCurrent(_ frame: Frame) async -> Bool {
        let rule = await gate.loadedRule
        let active = await gate.currentState == .active
        return active && rule?.targetItemID == frame.context.targetItemID && frame.generation == generation
    }
}
