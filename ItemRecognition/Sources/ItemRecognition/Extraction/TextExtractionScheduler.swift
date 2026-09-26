import CoreGraphics
import CoreVideo
import Foundation

/// Detects a label region and runs OCR only while `ActivationGate` is `.active`.
/// A supplied crop bypasses detection. Otherwise a detected region is required;
/// no region returns nil without running OCR. Both stages share one bounded slot.
///
/// Per submitted frame:
///
/// 1. Validate the image and optional crop. An invalid image throws before
///    the gate is consulted, so gate state is unchanged.
/// 2. Evaluate the gate with the supplied context. Any state other than
///    `.active` returns `nil`, resets the frame counter, and discards the
///    pending frame. The recognizer is not called.
/// 3. Count the frame. Only every `frameStride`-th frame while continuously
///    active is eligible (Notion: every 5th to 10th frame).
/// 4. One request may be in flight and one eligible frame may wait. A newer
///    eligible frame replaces the waiting one; the replaced submit returns
///    `nil`. There is no queue beyond that single slot.
/// 5. An in-flight request is allowed to finish. Its observation is returned
///    only if the gate is still `.active` for the same target when it
///    completes; otherwise the result is discarded and `nil` is returned.
///
/// The scheduler stores no OCR strings between frames and persists nothing.
/// `catalogCandidates(for:)` is never called here; matching is a later slice.
///
/// Ownership: the caller keeps `image.pixelBuffer` alive until `submit`
/// returns. Because a waiting frame's `submit` does not return until that
/// frame runs or is replaced, the buffer stays valid for the whole time this
/// actor might read it.
public actor TextExtractionScheduler {
    public static let strideRange: ClosedRange<Int> = 5...10
    public static let defaultStride = 5

    private let gate: ActivationGate
    private let recognizer: any TextRecognizing
    private let regionDetector: any LabelRegionDetecting
    private let normalizer: any TextNormalizing

    /// Clamped to `strideRange` at init. Immutable, so readable without hopping to the actor.
    public nonisolated let frameStride: Int

    private var framesWhileActive = 0
    private var generation: UInt = 0
    private var inFlight = false
    private var pending: PendingFrame?

    public init(
        gate: ActivationGate,
        recognizer: any TextRecognizing,
        normalizer: any TextNormalizing = TextNormalizer(),
        frameStride: Int = TextExtractionScheduler.defaultStride,
        regionDetector: any LabelRegionDetecting = VisionLabelRegionDetector()
    ) {
        self.gate = gate
        self.recognizer = recognizer
        self.regionDetector = regionDetector
        self.normalizer = normalizer
        self.frameStride = min(max(frameStride, Self.strideRange.lowerBound), Self.strideRange.upperBound)
    }

    /// True while the detection/OCR pipeline owns the processing slot.
    public var isRequestInFlight: Bool { inFlight }

    /// True while one eligible frame is waiting for the in-flight request.
    public var hasPendingFrame: Bool { pending != nil }

    /// Frames counted since the gate last became `.active`.
    public var framesSinceActivation: Int { framesWhileActive }

    /// Submits one frame with the context that accompanies it.
    ///
    /// Returns `nil` when OCR did not run for this frame. Returns an
    /// observation (possibly with zero candidates) when OCR ran and the gate
    /// was still `.active` at completion.
    public func submit(
        _ context: RecognitionContext,
        image: RecognitionImage,
        crop: CGRect? = nil
    ) async throws -> ProductTextObservation? {
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
            return nil
        }

        framesWhileActive += 1
        guard framesWhileActive % frameStride == 0 else {
            return nil
        }

        let frame = Frame(context: context, image: image, crop: crop, generation: generation)

        if inFlight {
            return try await enqueueReplacingPending(frame)
        }

        inFlight = true
        let outcome: Result<ProductTextObservation?, Error>
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
        let continuation: CheckedContinuation<ProductTextObservation?, Error>
    }

    private func enqueueReplacingPending(_ frame: Frame) async throws -> ProductTextObservation? {
        discardPending()
        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingFrame(frame: frame, continuation: continuation)
        }
    }

    private func discardPending() {
        guard let waiting = pending else { return }
        pending = nil
        waiting.continuation.resume(returning: nil)
    }

    private func startPendingIfAny() {
        guard let waiting = pending else { return }
        pending = nil
        inFlight = true
        Task { await self.runPending(waiting) }
    }

    private func runPending(_ waiting: PendingFrame) async {
        let outcome: Result<ProductTextObservation?, Error>
        do {
            outcome = .success(try await perform(waiting.frame))
        } catch {
            outcome = .failure(error)
        }
        inFlight = false
        waiting.continuation.resume(with: outcome)
        startPendingIfAny()
    }

    // MARK: - OCR

    private func perform(_ frame: Frame) async throws -> ProductTextObservation? {
        guard await isCurrent(frame) else { return nil }
        let crop: CGRect
        if let supplied = frame.crop {
            crop = supplied
        } else {
            guard let detected = try await regionDetector.detectRegion(in: frame.image) else { return nil }
            crop = detected
        }
        // Do not start OCR if a pause or target change arrived during detection.
        guard await isCurrent(frame) else { return nil }
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
            return nil
        }

        let candidates = lines.map { line in
            RecognizedTextCandidate(
                rawText: line.text,
                normalizedText: normalizer.normalize(line.text),
                confidence: line.confidence,
                boundingBox: line.boundingBox
            )
        }

        return ProductTextObservation(
            timestamp: frame.image.timestamp,
            targetItemID: frame.context.targetItemID,
            boundingBox: crop,
            candidates: candidates,
            side: rule?.side
        )
    }

    private func isCurrent(_ frame: Frame) async -> Bool {
        let rule = await gate.loadedRule
        let active = await gate.currentState == .active
        return active && rule?.targetItemID == frame.context.targetItemID && frame.generation == generation
    }
}
