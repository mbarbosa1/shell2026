import CoreGraphics
import Foundation
import Vision

/// `VNRecognizeTextRequest` wrapped behind `TextRecognizing`.
///
/// Settings recorded here so they are a stated decision rather than an
/// unnamed default: recognition level `.accurate`
///
/// The request runs on a detached utility task so the calling actor is not
/// blocked while Vision works. `RecognitionImage.orientation` is passed to
/// `VNImageRequestHandler`; the region of interest is passed to the request.
/// The pixel buffer is read only for the duration of `perform` and no
/// reference to it is kept.
/// 
///
public struct VisionTextRecognizer: TextRecognizing {
    public let recognitionLevel: VNRequestTextRecognitionLevel
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool

    public init(
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        recognitionLanguages: [String] = ["en-US"],
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(
        in image: RecognitionImage,
        regionOfInterest: CGRect?
    ) async throws -> [RecognizedTextLine] {
        let level = recognitionLevel
        let languages = recognitionLanguages
        let correction = usesLanguageCorrection

        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = correction
            if let regionOfInterest {
                request.regionOfInterest = regionOfInterest
            }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: image.pixelBuffer,
                orientation: image.orientation,
                options: [:]
            )
            try handler.perform([request])

            let observations = request.results ?? []
            return observations.compactMap { observation -> RecognizedTextLine? in
                guard let top = observation.topCandidates(1).first else { return nil }
                return RecognizedTextLine(
                    text: top.string,
                    confidence: top.confidence,
                    boundingBox: observation.boundingBox
                )
            }
        }.value
    }
}
