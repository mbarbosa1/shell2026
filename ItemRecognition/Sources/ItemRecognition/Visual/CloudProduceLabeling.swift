import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// One broad produce label suggested by a cloud vision model.
/// `confidence` is self-reported by the model, not a calibrated probability.
public struct CloudProduceLabel: Sendable, Equatable, Decodable {
    public let label: String
    public let confidence: Float
    public let model: String
    public init(label: String, confidence: Float, model: String) {
        self.label = label; self.confidence = confidence; self.model = model
    }
}

/// Sends one upright JPEG crop to a server that holds the provider API key.
/// Implementations must never embed a provider key in the app.
public protocol CloudProduceLabeling: Sendable {
    func label(jpeg: Data, allowedLabels: [String]) async throws -> CloudProduceLabel
}

/// Ask the cloud only after `weakFramesBeforeRequest` consecutive processed
/// frames whose best local produce score is below `localScoreBelow`. One blurry
/// video frame stays on device; a streak means this look will not confirm
/// locally. Each request resets the streak. `maximumRequestsPerItem` bounds
/// calls per classifier instance (one selected item per scan), and
/// `maximumRequests` remains a session backstop. The scheduler's single
/// inference slot already serializes requests, so a weak local frame is never
/// interleaved between cloud answers (that would reset temporal confirmation).
public struct CloudAssistPolicy: Sendable {
    public let localScoreBelow: Float
    public let weakFramesBeforeRequest: Int
    public let maximumRequestsPerItem: Int
    public let maximumRequests: Int
    public let maxImageDimension: CGFloat
    public init(localScoreBelow: Float = 0.8, weakFramesBeforeRequest: Int = 3, maximumRequestsPerItem: Int = 2,
                maximumRequests: Int = 200, maxImageDimension: CGFloat = 512) {
        self.localScoreBelow = localScoreBelow.isFinite ? min(max(localScoreBelow, 0), 1) : 0.8
        self.weakFramesBeforeRequest = max(1, weakFramesBeforeRequest)
        self.maximumRequestsPerItem = max(0, maximumRequestsPerItem)
        self.maximumRequests = max(0, maximumRequests)
        self.maxImageDimension = maxImageDimension.isFinite ? max(64, maxImageDimension) : 512
    }
}

public enum CloudRecognitionError: Error, LocalizedError, Equatable {
    case encodingFailed, httpStatus(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The camera crop could not be encoded for cloud assist."
        case .httpStatus(let code): return "The cloud assist proxy returned HTTP \(code)."
        case .invalidResponse: return "The cloud assist proxy returned an invalid label."
        }
    }
}

/// Client for `ItemRecognition/CloudProxy/server.py`. `token` authenticates the
/// app to that proxy only; the Gemini API key stays on the server.
public struct HTTPCloudProduceLabeler: CloudProduceLabeling {
    private let endpoint: URL
    private let token: String?
    private let timeout: TimeInterval
    private let session: URLSession

    /// Answers slower than the temporal gap (2 s by default) cannot chain into a confirmation.
    public init(endpoint: URL, token: String? = nil, timeout: TimeInterval = 4, session: URLSession = .shared) {
        self.endpoint = endpoint; self.token = token; self.timeout = timeout; self.session = session
    }

    public func label(jpeg: Data, allowedLabels: [String]) async throws -> CloudProduceLabel {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "image_base64": jpeg.base64EncodedString(), "labels": allowedLabels,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudRecognitionError.invalidResponse }
        guard http.statusCode == 200 else { throw CloudRecognitionError.httpStatus(http.statusCode) }
        guard let label = try? JSONDecoder().decode(CloudProduceLabel.self, from: data) else {
            throw CloudRecognitionError.invalidResponse
        }
        return label
    }
}

enum CloudImageEncoder {
    /// Upright, downscaled JPEG of a top-left original-buffer pixel crop.
    static func jpeg(_ image: RecognitionImage, crop: CGRect, maxDimension: CGFloat,
                     context: CIContext) throws -> Data {
        let height = image.imageResolution.height
        let lowerLeft = CGRect(x: crop.minX, y: height - crop.maxY, width: crop.width, height: crop.height)
        var output = CIImage(cvPixelBuffer: image.pixelBuffer).cropped(to: lowerLeft).oriented(image.orientation)
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
        let scale = min(1, maxDimension / max(output.extent.width, output.extent.height))
        if scale < 1 { output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: output, colorSpace: space,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
        else { throw CloudRecognitionError.encodingFailed }
        return data
    }
}
