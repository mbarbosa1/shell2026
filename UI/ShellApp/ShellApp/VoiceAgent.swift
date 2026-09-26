import AVFoundation
import Combine
import ElevenLabs
import Foundation

/// Connects the app to an ElevenLabs agent: streams the microphone, plays the agent's voice,
/// and runs the agent's client tools against `AppModel`.
///
/// The tools in `run(_:parameters:)` must also be added to the agent in the ElevenLabs
/// dashboard (Agent → Tools → Add tool → Client), with the same names and parameters
/// and "Wait for response" turned on.
@MainActor
final class VoiceAgent {
    private unowned let model: AppModel
    private var conversation: Conversation?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
    }

    func start() async {
        guard conversation == nil else { return }
        guard let agentID = VoiceConfig.agentID else {
            model.voiceError = "Voice is off: set ELEVENLABS_AGENT_ID in the scheme's environment variables."
            return
        }
        model.voiceError = nil

        // Ask here rather than leaving it to the SDK, which only asks after it has a token,
        // so a token failure would otherwise hide the prompt.
        guard await AVAudioApplication.requestRecordPermission() else {
            model.voiceError = "Microphone access is off. Turn it on in Settings → ShellApp → Microphone."
            return
        }

        let config = ConversationConfig(
            onDisconnect: { [weak self] _ in
                Task { @MainActor in self?.didDisconnect() }
            },
            onError: { [weak self] error in
                Task { @MainActor in self?.model.voiceError = error.localizedDescription }
            },
            onUserTranscript: { [weak self] text, _ in
                Task { @MainActor in self?.model.transcript = text }
            },
            onUnhandledClientToolCall: { [weak self] call in
                Task { @MainActor in await self?.handle(call) }
            }
        )

        do {
            let conversation = try await ElevenLabs.startConversation(auth: auth(agentID: agentID), config: config)
            self.conversation = conversation
            conversation.$isMuted
                .sink { [weak self] isMuted in self?.model.isListening = !isMuted }
                .store(in: &subscriptions)
        } catch {
            model.voiceError = error.localizedDescription
        }
    }

    func stop() async {
        await conversation?.endConversation()
        didDisconnect()
    }

    /// Mutes or unmutes the microphone, connecting first if needed.
    func setListening(_ isListening: Bool) async {
        guard let conversation else {
            if isListening { await start() }
            return
        }
        do {
            try await conversation.setMuted(!isListening)
        } catch {
            model.voiceError = error.localizedDescription
        }
    }

    private func didDisconnect() {
        conversation = nil
        subscriptions.removeAll()
        model.isListening = false
    }

    // MARK: Authentication

    private func auth(agentID: String) -> ElevenLabsConfiguration {
        #if DEBUG
        // Private agent: get a conversation token with the API key.
        if let apiKey = VoiceConfig.apiKey {
            return .customTokenProvider {
                try await VoiceAgent.fetchConversationToken(agentID: agentID, apiKey: apiKey)
            }
        }
        #endif
        // Public agent: the agent ID is enough.
        return .publicAgent(id: agentID)
    }

    /// DEBUG ONLY. Asks ElevenLabs for a conversation token using the API key.
    /// Before shipping, move this request to a backend and have the app call that instead.
    private nonisolated static func fetchConversationToken(agentID: String, apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/convai/conversation/token")!
        components.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // e.g. 401 {"detail":{"status":"invalid_api_key",...}}
            let body = String(decoding: data, as: UTF8.self)
            throw ConversationError.authenticationFailed("Token request failed (\(status)): \(body)")
        }
        struct TokenResponse: Decodable { let token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    // MARK: Client tools

    private func handle(_ call: ClientToolCallEvent) async {
        let parameters = (try? call.getParameters()) ?? [:]
        let result = run(call.toolName, parameters: parameters)

        guard call.expectsResponse else {
            conversation?.markToolCallCompleted(call.toolCallId)
            return
        }
        do {
            try await conversation?.sendToolResult(for: call.toolCallId, result: result.message, isError: result.isError)
        } catch {
            model.voiceError = error.localizedDescription
        }
    }

    /// Runs one tool and returns the text the agent reads back.
    private func run(_ tool: String, parameters: [String: Any]) -> (message: String, isError: Bool) {
        let name = parameters["name"] as? String

        switch tool {
        case "get_list":
            return (model.listSummary, false)

        case "add_item":
            guard let name else { return ("Missing parameter: name.", true) }
            model.addItem(GroceryItem(
                name: name,
                brand: parameters["brand"] as? String,
                label: parameters["label"] as? String,
                size: parameters["size"] as? String,
                quantity: parameters["quantity"] as? Int ?? 1
            ))
            return ("Added \(name) to the list.", false)

        case "remove_item":
            guard let name else { return ("Missing parameter: name.", true) }
            return model.removeItem(named: name)
                ? ("Removed \(name) from the list.", false)
                : ("\(name) isn't on the list.", true)

        case "check_off_item":
            guard let name else { return ("Missing parameter: name.", true) }
            return model.checkOffItem(named: name)
                ? ("Checked off \(name).", false)
                : ("\(name) isn't on the list.", true)

        case "add_usuals":
            model.addUsualsToList()
            return ("Added the usuals. \(model.listSummary)", false)

        case "open_camera":
            model.isCameraOpen = true
            return ("Camera opened.", false)

        case "close_camera":
            model.isCameraOpen = false
            return ("Camera closed.", false)

        default:
            return ("Unknown tool: \(tool).", true)
        }
    }
}
