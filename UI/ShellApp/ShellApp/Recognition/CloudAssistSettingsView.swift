#if DEBUG
import ItemRecognition
import SwiftUI

/// Shared by the trial setup and the camera's troubleshooting sheet.
struct CloudAssistSettingsSection: View {
    @AppStorage(CloudAssistConfig.endpointKey) private var endpoint = ""
    @AppStorage(CloudAssistConfig.tokenKey) private var token = ""
    @State private var checking = false
    @State private var result: String?

    var body: some View {
        Section {
            TextField("http://your-mac.local:8787/v1/produce-label", text: $endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel("Gemini proxy URL")
                .disabled(CloudAssistConfig.usesEnvironment)
            SecureField("Proxy token, if required", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(CloudAssistConfig.tokenUsesEnvironment)
            if CloudAssistConfig.usesEnvironment {
                Text("Using the proxy URL from the Xcode launch environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if CloudAssistConfig.tokenUsesEnvironment {
                Text("Using the proxy token from the Xcode launch environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await checkConnection() }
            } label: {
                HStack {
                    Label("Test connection", systemImage: "network")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(checking || CloudAssistConfig.endpoint == nil)
            if let result { Text(result).font(.footnote).textSelection(.enabled) }
            if CloudAssistConfig.endpoint == nil {
                Label("Gemini is unavailable until a valid proxy URL is set.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Gemini fallback")
        } footer: {
            Text("Apple Vision gets 5 seconds first, then Gemini can try twice. Use your Mac's network address, not localhost. Changes apply to the next trial. The Gemini API key stays on the proxy server.")
        }
        .onChange(of: endpoint) { result = nil }
        .onChange(of: token) { result = nil }
    }

    @MainActor
    private func checkConnection() async {
        guard let url = CloudAssistConfig.endpoint else { return }
        checking = true
        result = nil
        defer { checking = false }
        do {
            let status = try await CloudProxyStatus.check(url)
            guard url == CloudAssistConfig.endpoint else { return }
            if !status.ok { result = "The proxy answered, but reported that it is not ready." }
            else if status.mock { result = "Connection works, but the proxy is in MOCK mode. Its labels are not real recognition results." }
            else { result = "Proxy reachable · \(status.model). This checks connectivity only; the token and Gemini access are verified on the first image request." }
        } catch {
            guard url == CloudAssistConfig.endpoint else { return }
            result = "Connection failed: \(error.localizedDescription)"
        }
    }
}
#endif
