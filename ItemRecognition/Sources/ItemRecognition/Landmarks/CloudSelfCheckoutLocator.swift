import CoreGraphics
import CoreImage
import Foundation

/// Gemini's answer from `ItemRecognition/CloudProxy` (`POST /v1/self-checkout`).
public struct CloudSelfCheckoutAnswer: Sendable, Equatable, Decodable {
    public let found: Bool
    /// `[ymin, xmin, ymax, xmax]` as 0–1 fractions of the upright image sent, or nil.
    public let box: [Double]?
    /// Self-reported by the model, not calibrated.
    public let confidence: Float
    public let model: String

    public init(found: Bool, box: [Double]?, confidence: Float, model: String) {
        self.found = found; self.box = box; self.confidence = confidence; self.model = model
    }

    /// The sighting in `image`'s stored-buffer pixels, or nil when nothing was found. A found
    /// machine without a usable box is an invalid response.
    public func sighting(imageSize: CGSize, orientation: CGImagePropertyOrientation) throws -> SelfCheckoutSighting? {
        guard found else { return nil }
        guard let box, box.count == 4, box[0] < box[2], box[1] < box[3],
              box.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw CloudRecognitionError.invalidResponse }
        // The upright image with its origin at the top left, as Vision's bottom-left region.
        let region = CGRect(x: box[1], y: 1 - box[2], width: box[3] - box[1], height: box[2] - box[0])
        let pixels = try VisionRegionOfInterest.pixelCrop(normalizedRegion: region, imageSize: imageSize,
                                                         orientation: orientation)
        return SelfCheckoutSighting(box: pixels, confidence: confidence, source: .cloud(model: model), evidence: "Gemini")
    }
}

/// Client for the proxy's `/v1/self-checkout`. `token` authenticates the app to that proxy only;
/// the Gemini API key stays on the server. A call slower than `timeout` fails, and
/// `SelfCheckoutFinder` asks Apple Vision instead.
public actor HTTPCloudSelfCheckoutLocator: SelfCheckoutLocating {
    private let endpoint: URL
    private let token: String?
    private let timeout: TimeInterval
    private let maxImageDimension: CGFloat
    private let session: URLSession
    private lazy var imageContext = CIContext()

    public init(endpoint: URL, token: String? = nil, timeout: TimeInterval = 4, maxImageDimension: CGFloat = 768,
                session: URLSession = .shared) {
        self.endpoint = endpoint; self.token = token; self.timeout = timeout
        self.maxImageDimension = maxImageDimension; self.session = session
    }

    /// The self-checkout endpoint on the same proxy as `labelEndpoint` (`CLOUD_PROXY_URL`, which
    /// names the produce endpoint).
    public static func endpoint(besides labelEndpoint: URL) -> URL {
        var parts = URLComponents(url: labelEndpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = "/v1/self-checkout"
        return parts.url ?? labelEndpoint
    }

    public func locate(_ image: RecognitionImage) async throws -> SelfCheckoutSighting? {
        // The whole frame, upright and downscaled: the answer's box is in that image.
        let jpeg = try CloudImageEncoder.jpeg(image, crop: CGRect(origin: .zero, size: image.imageResolution),
                                              maxDimension: maxImageDimension, context: imageContext)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["image_base64": jpeg.base64EncodedString()])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudRecognitionError.invalidResponse }
        guard http.statusCode == 200 else { throw CloudRecognitionError.httpStatus(http.statusCode) }
        guard let answer = try? JSONDecoder().decode(CloudSelfCheckoutAnswer.self, from: data) else {
            throw CloudRecognitionError.invalidResponse
        }
        return try answer.sighting(imageSize: image.imageResolution, orientation: image.orientation)
    }
}
