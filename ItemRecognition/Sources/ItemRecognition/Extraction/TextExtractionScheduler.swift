import CoreGraphics
import Foundation

/// Compatibility facade for the existing OCR API. Both recognition modes use
/// RecognitionFrameScheduler internally; there is no second inference queue.
public actor TextExtractionScheduler {
    public static let strideRange = 5...10
    public static let defaultStride = 5
    private let scheduler: RecognitionFrameScheduler
    public nonisolated let frameStride: Int

    public init(gate: ActivationGate, recognizer: any TextRecognizing,
                normalizer: any TextNormalizing = TextNormalizer(),
                frameStride: Int = TextExtractionScheduler.defaultStride,
                regionDetector: any LabelRegionDetecting = VisionLabelRegionDetector()) {
        self.frameStride = min(max(frameStride, Self.strideRange.lowerBound), Self.strideRange.upperBound)
        scheduler = RecognitionFrameScheduler(gate: gate, recognizer: recognizer, normalizer: normalizer,
                                              frameStride: frameStride, regionDetector: regionDetector)
    }
    public var isRequestInFlight: Bool { get async { await scheduler.isRequestInFlight } }
    public var hasPendingFrame: Bool { get async { await scheduler.hasPendingFrame } }
    public var framesSinceActivation: Int { get async { await scheduler.framesSinceActivation } }
    public func invalidate() async { await scheduler.invalidate() }
    public func submit(_ context: RecognitionContext, image: RecognitionImage,
                       crop: CGRect? = nil) async throws -> ProductTextObservation? {
        switch try await scheduler.submit(context, image: image, crop: crop) {
        case .processed(.text(let observation, _, _)): return observation
        default: return nil
        }
    }
    static func validate(_ image: RecognitionImage, crop: CGRect?) throws {
        try RecognitionFrameScheduler.validate(image, crop: crop)
    }
}
