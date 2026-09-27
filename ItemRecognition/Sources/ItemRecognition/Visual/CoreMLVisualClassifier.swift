import CoreGraphics
import CoreML
import Foundation
import Vision

/// Inject a real, compiled classifier from the application/model owner.
/// The model remains resident on this actor. No download or training happens here.
public actor CoreMLVisualClassifier: VisualClassifying {
    public enum CropAndScale: Sendable {
        case centerCrop, scaleFit, scaleFill
        fileprivate var vision: VNImageCropAndScaleOption {
            switch self {
            case .centerCrop: return .centerCrop
            case .scaleFit: return .scaleFit
            case .scaleFill: return .scaleFill
            }
        }
    }
    private let request: VNCoreMLRequest
    private let info: VisualModelInfo

    /// Accepts an image classifier or a Create ML object detector. Detector
    /// pipelines may not publish `classLabels`; pass the class list recorded in
    /// `Training/` as `classLabels` for those.
    public init(compiledModelURL: URL, modelID: String, version: String, cropAndScale: CropAndScale,
                classLabels: [String]? = nil) throws {
        guard FileManager.default.fileExists(atPath: compiledModelURL.path) else {
            throw VisualRecognitionError.missingModel
        }
        let model = try MLModel(contentsOf: compiledModelURL)
        guard !modelID.isEmpty, !version.isEmpty,
              let labels = (model.modelDescription.classLabels as? [String]) ?? classLabels, !labels.isEmpty else {
            throw VisualRecognitionError.incompatibleModel
        }
        info = VisualModelInfo(id: modelID, version: version, supportedClassIDs: Set(labels))
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = cropAndScale.vision
    }

    public func modelInfo() -> VisualModelInfo { info }

    public func classify(in image: RecognitionImage, crop: CGRect?) throws -> VisualObservation {
        try TextExtractionScheduler.validate(image, crop: crop)
        let region = crop ?? CGRect(origin: .zero, size: image.imageResolution)
        request.regionOfInterest = try VisionRegionOfInterest.normalized(
            pixelCrop: region, imageSize: image.imageResolution, orientation: image.orientation)
        try VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                  orientation: image.orientation, options: [:]).perform([request])
        let classifications: [VisualClassification]
        if let objects = request.results as? [VNRecognizedObjectObservation] {
            // Boxes are collapsed to the best score per label; the pipeline still
            // assumes one prominent item per crop.
            var best: [String: Float] = [:]
            for label in objects.flatMap(\.labels) { best[label.identifier] = max(best[label.identifier] ?? 0, label.confidence) }
            classifications = best.map { VisualClassification(identifier: $0.key, score: $0.value) }
        } else if let results = request.results as? [VNClassificationObservation] {
            classifications = results.map { VisualClassification(identifier: $0.identifier, score: $0.confidence) }
        } else {
            throw VisualRecognitionError.incompatibleModel
        }
        return VisualObservation(timestamp: image.timestamp, modelID: info.id, modelVersion: info.version,
            inputRegion: region, classifications: classifications)
    }
}
