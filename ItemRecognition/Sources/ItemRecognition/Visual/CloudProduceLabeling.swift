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

/// Apple Vision first; Gemini only when it has not found the item. After detection
/// turns on, Apple Vision works alone for `appleVisionSeconds`; then one Gemini call
/// is made, and after each call that did not lead to a question Apple Vision gets
/// the same time again. `maximumRequestsPerItem` caps calls for one item scan and
/// `maximumRequests` is a backstop.
public struct CloudAssistPolicy: Sendable {
    public let maximumRequestsPerItem: Int
    public let maximumRequests: Int
    public let maxImageDimension: CGFloat
    public let appleVisionSeconds: TimeInterval
    public init(maximumRequestsPerItem: Int = 2, maximumRequests: Int = 200, maxImageDimension: CGFloat = 512,
                appleVisionSeconds: TimeInterval = 5) {
        self.appleVisionSeconds = appleVisionSeconds.isFinite ? max(0, appleVisionSeconds) : 5
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

    /// A call slower than `timeout` fails, and Apple Vision's result for that frame stands.
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

/// `/healthz` from `ItemRecognition/CloudProxy/server.py`.
public struct CloudProxyStatus: Sendable, Equatable, Decodable {
    public let ok: Bool
    public let mock: Bool
    public let model: String

    public static let defaultModel = "gemini-3.1-flash-lite"

    public static func healthzURL(from labelEndpoint: URL) -> URL {
        var parts = URLComponents(url: labelEndpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = "/healthz"
        return parts.url ?? labelEndpoint
    }

    public static func fetch(from labelEndpoint: URL, session: URLSession = .shared) async -> String {
        guard let status = try? await check(labelEndpoint, session: session), !status.model.isEmpty else { return defaultModel }
        return status.model
    }

    /// Asks the proxy's `/healthz`, which costs no Gemini call. It does not check the
    /// token: a wrong token shows up as HTTP 401 on the first produce call.
    public static func check(_ labelEndpoint: URL, session: URLSession = .shared,
                             timeout: TimeInterval = 4) async throws -> CloudProxyStatus {
        let (data, response) = try await session.data(for: URLRequest(url: healthzURL(from: labelEndpoint),
                                                                      timeoutInterval: timeout))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudRecognitionError.httpStatus(code) }
        guard let status = try? JSONDecoder().decode(CloudProxyStatus.self, from: data) else {
            throw CloudRecognitionError.invalidResponse
        }
        return status
    }

    enum CodingKeys: String, CodingKey { case ok, mock, model }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decode(Bool.self, forKey: .ok)
        mock = try values.decodeIfPresent(Bool.self, forKey: .mock) ?? false
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
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
