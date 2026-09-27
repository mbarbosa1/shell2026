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
    /// Whether the microphone should be on. Applied once connected, so a change made while
    /// connecting isn't lost.
    private var wantsMicrophone = true

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
        // A new conversation starts fresh, so words from the last one can't close a list.
        model.transcript = nil

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
            // Shopping connects with the mic off (see `setMicrophone(on:)`).
            if conversation.isMuted == wantsMicrophone {
                try await conversation.setMuted(!wantsMicrophone)
            }
        } catch {
            model.voiceError = error.localizedDescription
        }
    }

    func stop() async {
        await conversation?.endConversation()
        didDisconnect()
    }

    /// Turning listening on connects to Mira, or turns her mic back on if she's connected with it
    /// off. Turning it off ends the conversation, so she stops talking right away; muting only the
    /// microphone would let her keep speaking (and keep the session billing). The list lives in the
    /// database, so nothing is lost between sessions.
    func setListening(_ isListening: Bool) async {
        if isListening {
            await setMicrophone(on: true)
        } else {
            await stop()
        }
    }

    /// Turns only the microphone on or off: Mira stays connected and can still talk. Connects
    /// first if she isn't yet. Used while shopping, where she only listens at a stop.
    func setMicrophone(on: Bool) async {
        wantsMicrophone = on
        guard let conversation else {
            await start()
            return
        }
        guard conversation.isMuted == on else { return }
        do {
            try await conversation.setMuted(!on)
        } catch {
            model.voiceError = error.localizedDescription
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
    ///   `block`, `in_cart` (boolean). Checking an item off is `name` + `in_cart` true.
    /// - `set_item_location`: `name`, `aisle` (integer), `block`
    /// - `remove_grocery_item` / `remove_item`: `name`
    /// - `check_off_item`: `name`. Older agents only; use `update_grocery_item` with `in_cart` true.
    /// - `add_usuals`, `get_most_common_items`, `get_last_trip`, `open_camera_or_close`,
    ///   `open_camera`, `close_camera`, `analyze_current_frame`, `cancel_current_operation`: none.
    ///   When the camera asks "Is this Oat milk?", `check_off_item` is yes and
    ///   `cancel_current_operation` is no.
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
            if let error = Self.missingAisleError(Self.int(parameters["aisle"])) { return error }
            let item = GroceryItem(
                name: name,
                brand: Self.text(parameters["brand"]),
                label: Self.text(parameters["label"]),
                size: Self.text(parameters["size"]),
                quantity: Self.int(parameters["quantity"]) ?? 1,
                aisle: Self.int(parameters["aisle"]),
                block: Self.text(parameters["block"])?.uppercased()
            )
            model.addItem(item, source: .voice)
            // Tell the user the product and price we picked, but not the aisle.
            guard let product = model.product(for: item), let price = item.price else {
                return ("Added \(name) to the list. The store's catalog doesn't have it, so there's no price.", false)
            }
            let size = product.size.map { ", \($0)" } ?? ""
            return ("Added \(name) to the list: \(ProductMatcher.ownName(of: product.title))\(size), "
                + "for \(price.formatted(.currency(code: "USD"))).", false)

        case "update_grocery_item", "update_item":
            guard let name else { return ("Missing parameter: name.", true) }
            let quantity = Self.int(parameters["quantity"])
            let aisle = Self.int(parameters["aisle"])
            if let error = Self.missingAisleError(aisle) { return error }
            let block = Self.text(parameters["block"])
            let isCollected = Self.bool(parameters["in_cart"])
            let brand = Self.text(parameters["brand"]), label = Self.text(parameters["label"]), size = Self.text(parameters["size"])
            let changes: [Any?] = [quantity, aisle, isCollected, block, brand, label, size]
            guard changes.contains(where: { $0 != nil }) else {
                return ("Nothing to update. Give a quantity, brand, label, size, aisle, block, or in_cart.", true)
            }
            // Only in_cart true is checking the item off, so answer the way check_off_item does.
            if isCollected == true, changes.compactMap({ $0 }).count == 1 {
                return checkOff(name)
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
            if let error = Self.missingAisleError(aisle) { return error }
            return model.updateItem(named: name, aisle: aisle, block: block, source: .voice)
                ? ("\(name) is in block \(block.uppercased()), aisle \(aisle).", false)
                : ("\(name) isn't on the list.", true)

        case "remove_grocery_item", "remove_item":
            guard let name else { return ("Missing parameter: name.", true) }
            return model.removeItem(named: name, source: .voice)
                ? ("Removed \(name) from the list.", false)
                : ("\(name) isn't on the list.", true)

        case "check_off_item":
            // Kept for agents still set up with it; update_grocery_item with in_cart true does the same.
            guard let name else { return ("Missing parameter: name. Call update_grocery_item with name and in_cart true.", true) }
            return checkOff(name)

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
            // Only the user can close a list: check what they actually said, not the agent's guess.
            guard Self.saidFinished(model.transcript) else {
                return ("Not finished: the user didn't say they're done. Keep list \(model.currentList.number) open. "
                    + "Only call this after they say something like \"I'm done shopping\" or \"close my list\".", true)
            }
            let finished = model.finishList(at: Self.text(parameters["store"]), source: .voice)
            return ("Saved list \(finished.number) to History and started list \(model.currentList.number).", false)

        case "open_camera", "open_camera_or_close":
            // Only opens: the camera closes at the cashier or with the X on screen.
            return ("Camera opened. Let's start shopping." + Self.notInCatalog(model.startShopping()), false)

        case "analyze_current_frame":
            return model.isCameraOpen
                ? (model.scanStatus, false)
                : ("The camera is closed. Open it first.", true)

        case "cancel_current_operation":
            // A "no" to the camera's "Is this …?" keeps it looking.
            return model.answerScan(false) ? ("Okay, the camera will keep looking.", false) : ("Cancelled.", false)

        case "close_camera":
            return ("The camera stays on until you reach the cashier. "
                + "To leave early, tap the close button in the top right corner.", true)

        case "next_page":
            return model.showOnboardingPage(model.onboardingPage + 1)

        case "previous_page":
            return model.showOnboardingPage(model.onboardingPage - 1)

        case "finish_onboarding":
            guard !model.hasOnboarded else { return ("Onboarding is already finished.", true) }
            model.finishOnboarding()
            return ("Onboarding finished. The user is now on their shopping list.", false)

        default:
            return ("Unknown tool: \(tool).", true)
        }
    }

    private func checkOff(_ name: String) -> (message: String, isError: Bool) {
        switch model.checkOffItem(named: name, source: .voice) {
        case .checkedOff: return ("Checked off \(name).", false)
        case .alreadyInCart: return ("\(name) is already in the cart.", false)
        case .notOnList: return ("\(name) isn't on the list.", true)
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

    /// True if the user's own words clearly say they're done, e.g. "I'm done shopping" or
    /// "close my list". "I'm not done yet" and anything without a finish phrase don't count.
    private static func saidFinished(_ transcript: String?) -> Bool {
        guard let transcript else { return false }
        let said = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
        let negations = ["not done", "not finished", "n't done", "n't finished", "not yet", "not quite", "almost done"]
        guard !negations.contains(where: said.contains) else { return false }
        let finishPhrases = [
            "i'm done", "im done", "i am done", "we're done", "we are done", "all done",
            "i'm finished", "im finished", "i am finished", "we're finished", "we are finished",
            "done shopping", "finished shopping", "done with my list", "done with the list",
            "finish my list", "finish the list", "finish list", "close my list", "close the list", "close list",
            "finish my trip", "finish the trip", "end my trip", "end the trip", "end my list",
            "that's all", "thats all", "that is all", "that's everything", "that is everything",
        ]
        return finishPhrases.contains(where: said.contains)
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

    /// " Not in the store's catalog: whole milk, bread." or nothing when everything was found.
    private static func notInCatalog(_ items: [GroceryItem]) -> String {
        items.isEmpty ? "" : " Not in the store's catalog: \(items.map(\.name).joined(separator: ", "))."
    }

    /// The agent may send numbers as integers, decimals, or text.
    /// Aisles this store doesn't have, so nothing can be put in them. The catalog has none of them
    /// either (Scripts/output/products.json).
    private static let missingAisles: Set<Int> = [10]

    private static func missingAisleError(_ aisle: Int?) -> (String, Bool)? {
        guard let aisle, missingAisles.contains(aisle) else { return nil }
        return ("There's no aisle \(aisle) in this store.", true)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
