import Foundation
import ItemRecognition

/// Where the Gemini cloud-assist proxy (`ItemRecognition/CloudProxy`) runs, read from the app's
/// environment variables, like `VoiceConfig`: Product → Scheme → Edit Scheme… → Run → Arguments →
/// Environment Variables. The scheme lives in `xcuserdata/`, which git ignores.
///
/// Only produce uses it: Apple Vision looks first, and Gemini is asked only after 5 s at the item
/// without a question, at most twice per item. With no address set, recognition stays on the phone.
enum CloudAssistConfig {
    /// `CLOUD_PROXY_URL`, e.g. `http://my-mac.local:8787/v1/produce-label`.
    static var endpoint: URL? {
        value(named: "CLOUD_PROXY_URL").flatMap(URL.init(string:)).flatMap { url in
            (url.scheme == "http" || url.scheme == "https") && url.host != nil ? url : nil
        }
    }

    /// `CLOUD_PROXY_TOKEN`: the password made up for the proxy (`PROXY_TOKEN`), not the Gemini key.
    static var token: String? { value(named: "CLOUD_PROXY_TOKEN") }

    /// The proxy client, or nil when no address is set.
    static func labeler() -> (any CloudProduceLabeling)? {
        endpoint.map { HTTPCloudProduceLabeler(endpoint: $0, token: token) }
    }

    private static func value(named name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }
}
