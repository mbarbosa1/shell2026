import Foundation
import ItemRecognition

/// Where the Gemini proxy runs. Test settings persist on the phone; Xcode launch
/// environment variables override them when supplied. The provider key stays on the server.
///
/// Only produce uses it: Apple Vision looks first, and Gemini is asked only after 5 s at the item
/// without a question, at most twice per item. With no address set, recognition stays on the phone.
enum CloudAssistConfig {
    static let endpointKey = "recognition.cloud.endpoint"
    static let tokenKey = "recognition.cloud.token"

    static var usesEnvironment: Bool { value(named: "CLOUD_PROXY_URL") != nil }
    static var tokenUsesEnvironment: Bool { value(named: "CLOUD_PROXY_TOKEN") != nil }
    static var endpointText: String {
        value(named: "CLOUD_PROXY_URL") ?? UserDefaults.standard.string(forKey: endpointKey) ?? ""
    }

    /// `CLOUD_PROXY_URL`, e.g. `http://my-mac.local:8787/v1/produce-label`.
    static var endpoint: URL? {
        URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { url in
            (url.scheme == "http" || url.scheme == "https") && url.host != nil ? url : nil
        }
    }

    /// `CLOUD_PROXY_TOKEN`: the password made up for the proxy (`PROXY_TOKEN`), not the Gemini key.
    static var token: String? {
        value(named: "CLOUD_PROXY_TOKEN") ?? UserDefaults.standard.string(forKey: tokenKey)
    }

    /// The proxy client, or nil when no address is set.
    static func labeler() -> (any CloudProduceLabeling)? {
        endpoint.map { HTTPCloudProduceLabeler(endpoint: $0, token: token) }
    }

    /// The same proxy's self-checkout finder (`/v1/self-checkout`), or nil when no address is set.
    /// Unlike produce, Gemini is asked first here and Apple Vision is the fallback (user decision,
    /// September 27, 2026; see `SelfCheckoutFinder`).
    static func checkoutLocator() -> (any SelfCheckoutLocating)? {
        endpoint.map { HTTPCloudSelfCheckoutLocator(endpoint: HTTPCloudSelfCheckoutLocator.endpoint(besides: $0), token: token) }
    }

    private static func value(named name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }
}
