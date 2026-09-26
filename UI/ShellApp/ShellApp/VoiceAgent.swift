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

    /// Connects to the agent. Called when the user first turns listening on, never at launch.
    func start() async {
        // A second tap while connecting would otherwise open a second conversation.
        guard conversation == nil, !model.isConnectingVoice else { return }
        model.isConnectingVoice = true
        defer { model.isConnectingVoice = false }

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
            model.isVoiceConnected = true
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

    /// Turning listening on connects to Mira. Turning it off ends the conversation, so she stops
    /// talking right away; muting only the microphone would let her keep speaking (and keep the
    /// session billing). The list lives in the database, so nothing is lost between sessions.
    func setListening(_ isListening: Bool) async {
        if isListening {
            await start()
        } else {
            await stop()
        }
    }

    private func didDisconnect() {
        conversation = nil
        subscriptions.removeAll()
        model.isListening = false
        model.isVoiceConnected = false
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
        #if DEBUG
        print("🛒 \(call.toolName) \(parameters) → \(result.isError ? "ERROR: " : "")\(result.message)")
        print(model.databaseSnapshot)
        #endif

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

    /// Runs one tool and returns the text the agent reads back. Every change is saved to the
    /// grocery database and logged in the list's history as coming from voice.
    ///
    /// Tools answer to the dashboard's names (`add_grocery_item`) and the short ones (`add_item`).
    /// Parameters (all strings unless noted; the item's name can be `name` or `item_name`):
    /// - `get_grocery_list` / `get_list`: `number` (integer, optional; the open list if left out)
    /// - `add_grocery_item` / `add_item`: `name`, and optional `brand`, `label`, `size`,
    ///   `quantity` (integer), `aisle` (integer), `block` (e.g. "G")
    /// - `update_grocery_item`: `name`, and any of `quantity`, `brand`, `label`, `size`, `aisle`,
    ///   `block`, `in_cart` (boolean)
    /// - `set_item_location`: `name`, `aisle` (integer), `block`
    /// - `remove_grocery_item` / `remove_item`, `check_off_item`: `name`
    /// - `add_usuals`, `get_most_common_items`, `get_last_trip`, `open_camera_or_close`,
    ///   `open_camera`, `close_camera`, `analyze_current_frame`, `cancel_current_operation`: none
    /// - `get_list_history`: `number` (integer, optional; the open list if left out)
    /// - `finish_list` / `finished_list`: `store` (optional), e.g. "Publix"
    private func run(_ tool: String, parameters: [String: Any]) -> (message: String, isError: Bool) {
        let name = Self.text(parameters["name"] ?? parameters["item_name"])

        switch tool {
        case "get_grocery_list", "get_list":
            guard let list = list(numbered: parameters["number"]) else { return (noSuchList(parameters["number"]), true) }
            return (model.summary(of: list), false)

        case "add_grocery_item", "add_item":
            guard let name else { return ("Missing parameter: name.", true) }
            model.addItem(GroceryItem(
                name: name,
                brand: Self.text(parameters["brand"]),
                label: Self.text(parameters["label"]),
                size: Self.text(parameters["size"]),
                quantity: Self.int(parameters["quantity"]) ?? 1,
                aisle: Self.int(parameters["aisle"]),
                block: Self.text(parameters["block"])?.uppercased()
            ), source: .voice)
            return ("Added \(name) to list \(model.currentList.number).", false)

        case "update_grocery_item", "update_item":
            guard let name else { return ("Missing parameter: name.", true) }
            let quantity = Self.int(parameters["quantity"])
            let aisle = Self.int(parameters["aisle"])
            let block = Self.text(parameters["block"])
            let isCollected = Self.bool(parameters["in_cart"])
            let brand = Self.text(parameters["brand"]), label = Self.text(parameters["label"]), size = Self.text(parameters["size"])
            let changes: [Any?] = [quantity, aisle, isCollected, block, brand, label, size]
            guard changes.contains(where: { $0 != nil }) else {
                return ("Nothing to update. Give a quantity, brand, label, size, aisle, block, or in_cart.", true)
            }
            return model.updateItem(
                named: name, quantity: quantity, brand: brand, label: label, size: size,
                aisle: aisle, block: block, isCollected: isCollected, source: .voice
            )
                ? ("Updated \(name). \(model.listSummary)", false)
                : ("\(name) isn't on the list.", true)

        case "set_item_location":
            guard let name else { return ("Missing parameter: name.", true) }
            guard let aisle = Self.int(parameters["aisle"]), let block = Self.text(parameters["block"]) else {
                return ("Missing parameter: aisle and block are both needed.", true)
            }
            return model.updateItem(named: name, aisle: aisle, block: block, source: .voice)
                ? ("\(name) is in block \(block.uppercased()), aisle \(aisle).", false)
                : ("\(name) isn't on the list.", true)

        case "remove_grocery_item", "remove_item":
            guard let name else { return ("Missing parameter: name.", true) }
            return model.removeItem(named: name, source: .voice)
                ? ("Removed \(name) from the list.", false)
                : ("\(name) isn't on the list.", true)

        case "check_off_item":
            guard let name else { return ("Missing parameter: name.", true) }
            switch model.checkOffItem(named: name, source: .voice) {
            case .checkedOff: return ("Checked off \(name).", false)
            case .alreadyInCart: return ("\(name) is already in the cart.", false)
            case .notOnList: return ("\(name) isn't on the list.", true)
            }

        case "add_usuals":
            guard !model.usuals.isEmpty else { return ("There are no usuals yet. Items become usuals after they've been on two lists.", false) }
            model.addUsualsToList(source: .voice)
            return ("Added the usuals. \(model.listSummary)", false)

        case "get_most_common_items":
            return (model.mostCommonSummary, false)

        case "get_last_trip":
            guard let trip = model.trips.first else { return ("There are no finished trips yet.", false) }
            return (model.summary(of: trip), false)

        case "get_list_history":
            guard let list = list(numbered: parameters["number"]) else { return (noSuchList(parameters["number"]), true) }
            return (model.historySummary(of: list), false)

        case "finish_list", "finished_list":
            guard !model.items.isEmpty else {
                return ("List \(model.currentList.number) is empty, so there's no trip to finish. Add items first.", true)
            }
            let finished = model.finishList(at: Self.text(parameters["store"]), source: .voice)
            return ("Saved list \(finished.number) to History and started list \(model.currentList.number).", false)

        case "open_camera_or_close":
            model.isCameraOpen.toggle()
            return (model.isCameraOpen ? "Camera opened." : "Camera closed.", false)

        case "analyze_current_frame":
            // No computer vision in the app yet, so say so instead of guessing a direction.
            return model.isCameraOpen
                ? ("Frame analysis isn't connected yet, so I can't tell which way to turn.", true)
                : ("The camera is closed. Open it first.", true)

        case "cancel_current_operation":
            let wasOpen = model.isCameraOpen
            model.isCameraOpen = false
            return (wasOpen ? "Cancelled and closed the camera." : "Cancelled. Nothing was running.", false)

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

    /// The list with that number, or the open list if there's no number.
    private func list(numbered value: Any?) -> GroceryList? {
        guard let number = Self.int(value) else { return model.currentList }
        return model.list(number: number)
    }

    private func noSuchList(_ value: Any?) -> String {
        "There's no list \(Self.int(value).map(String.init) ?? "with that number")."
    }

    /// Trimmed text, or nil when it's missing or blank, so empty values are saved as NULL.
    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The agent may send true/false or text like "yes".
    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let text as String: return ["true", "yes", "1"].contains(text.lowercased()) ? true : ["false", "no", "0"].contains(text.lowercased()) ? false : nil
        default: return nil
        }
    }

    /// The agent may send numbers as integers, decimals, or text.
    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
