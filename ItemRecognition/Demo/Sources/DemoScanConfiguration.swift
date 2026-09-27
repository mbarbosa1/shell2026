import Foundation
import ItemRecognition

/// One demo scan: the preset item plus the Gemini proxy produce falls back to after Apple Vision.
struct DemoScanConfiguration: Hashable, Identifiable {
    static let endpointKey = "cloudAssist.endpoint"
    static let tokenKey = "cloudAssist.token"
    static let defaultModel = CloudProxyStatus.defaultModel

    let item: DemoItem
    let endpoint: URL?
    let token: String?
    var geminiModel: String

    var id: UUID { item.id }

    var usesGemini: Bool { item.recognizesByAppearance && endpoint != nil }

    func labeler() -> (any CloudProduceLabeling)? {
        guard let endpoint else { return nil }
        return HTTPCloudProduceLabeler(endpoint: endpoint, token: token)
    }

    static func load(item: DemoItem, endpointText: String, token: String) async -> Self {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = URL(string: trimmed).flatMap { url in
            (url.scheme == "http" || url.scheme == "https") && url.host != nil ? url : nil
        }
        var configuration = Self(item: item, endpoint: endpoint,
                                 token: token.isEmpty ? nil : token, geminiModel: defaultModel)
        if let endpoint {
            configuration.geminiModel = await CloudProxyStatus.fetch(from: endpoint)
        }
        return configuration
    }
}
