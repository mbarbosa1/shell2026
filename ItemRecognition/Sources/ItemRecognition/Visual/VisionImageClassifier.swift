import CoreGraphics
import Foundation
import Vision

/// Apple-supplied general image classifier. No text region or downloaded model
/// is needed. Classification describes a prominent item, not its location/SKU.
public actor VisionImageClassifier: VisualClassifying {
    public static let modelID = "apple.vision.classify-image"
    private let request: VNClassifyImageRequest
    private var info: VisualModelInfo?

    public init() {
        let request = VNClassifyImageRequest()
        request.revision = VisionRevisions.classify
        self.request = request
    }

    public func modelInfo() throws -> VisualModelInfo {
        if let info { return info }
        let value = VisualModelInfo(id: Self.modelID,
            version: "revision-\(request.revision); \(ProcessInfo.processInfo.operatingSystemVersionString)",
            supportedClassIDs: Set(try request.supportedIdentifiers()))
        info = value
        return value
    }

    public func classify(in image: RecognitionImage, crop: CGRect?) throws -> VisualObservation {
        try TextExtractionScheduler.validate(image, crop: crop)
        let info = try modelInfo()
        let region = crop ?? CGRect(origin: .zero, size: image.imageResolution)
        request.regionOfInterest = try VisionRegionOfInterest.normalized(
            pixelCrop: region, imageSize: image.imageResolution, orientation: image.orientation)
        let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                            orientation: image.orientation, options: [:])
        try handler.perform([request])
        return VisualObservation(timestamp: image.timestamp, modelID: info.id, modelVersion: info.version,
            inputRegion: region, classifications: (request.results ?? []).map {
                VisualClassification(identifier: $0.identifier, score: $0.confidence)
            })
    }
}
