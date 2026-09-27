import SwiftUI

struct ShopView: View {
    @Environment(AppModel.self) private var model
    @State private var isRouteOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Let’s shop")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                DeviceStatusRow(isConnected: model.isDeviceConnected)
                    .padding(.top, 6)

                ListeningHeader(isListening: model.isListening, hasStarted: model.isVoiceConnected)
                    .padding(.top, 16)

                if let voiceError = model.voiceError {
                    Text(voiceError)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)
                }

                if let transcript = model.transcript {
                    TranscriptCard(transcript: transcript, confirmation: model.confirmation)
                        .padding(.top, 12)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Your list")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("List \(model.currentList.number) · " + (model.items.count == 1 ? "1 item" : "\(model.items.count) items"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 20)

                VStack(spacing: 8) {
                    ForEach(model.items) { item in
                        GroceryRow(
                            item: item,
                            isChecked: item.isCollected,
                            isHighlighted: item.id == model.highlightedItemID
                        ) {
                            model.toggleCollected(item.id)
                        }
                    }
                }
                .padding(.top, 8)
                .animation(.default, value: model.items)

                VStack(spacing: 10) {
                    Button(listeningButtonTitle) {
                        Task { await model.setListening(!model.isListening) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isConnectingVoice)

                    if !model.cart.isEmpty {
                        Button("Finish trip") { model.finishList() }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityHint("Saves this list to History and starts a new one")
                    }

                    if !model.items.isEmpty {
                        Button("Show route") { isRouteOpen = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityHint("Shows the shortest way through the store to everything on your list")
                    }

                    Button("Start shopping") { model.startShopping() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityHint("Opens the camera on the shopping mount")
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(Theme.textPrimary)
        .sheet(isPresented: $isRouteOpen) { RouteView() }
    }

    /// Starting connects to Mira; stopping ends the conversation so she goes quiet right away.
    private var listeningButtonTitle: String {
        if model.isConnectingVoice { return "Connecting…" }
        return model.isListening ? "Stop listening" : "Start listening"
    }
}

// MARK: Pieces

struct DeviceStatusRow: View {
    let isConnected: Bool

    var body: some View {
        Label {
            Text(isConnected ? "Shopping device connected" : "Shopping device not connected")
        } icon: {
            Image(systemName: isConnected ? "checkmark.circle" : "exclamationmark.circle")
        }
        .font(.subheadline)
        .foregroundStyle(isConnected ? Theme.success : Theme.textSecondary)
    }
}

struct ListeningHeader: View {
    let isListening: Bool
    /// False until the user first turns listening on, so the header invites them to start.
    var hasStarted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(isListening ? "I’m listening" : hasStarted ? "Listening paused" : "Mira is ready")
                    .font(.title2.weight(.medium))
            } icon: {
                Image(systemName: isListening ? "waveform" : hasStarted ? "mic.slash" : "mic")
                    .foregroundStyle(isListening ? Theme.accentText : Theme.textSecondary)
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            }
            Text(
                isListening ? "Say “open camera” to scan an item."
                    : hasStarted ? "Resume listening when you’re ready."
                    : "Tap Start listening to make a list or start a trip."
            )
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

}

struct TranscriptCard: View {
    let transcript: String
    let confirmation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(transcript)”")
                .font(.title3)
            if let confirmation {
                Text(confirmation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentText)
            }
        }
        .padding(.vertical, 6)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct GroceryRow<Item: ItemDescribing>: View {
    let item: Item
    var isChecked: Bool
    var isHighlighted = false
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isChecked ? Theme.lavender : Theme.textPrimary.opacity(0.8))
        }
        .cardStyle(highlighted: isHighlighted)
        .contentShape(.rect)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.detail)")
                .accessibilityValue(isChecked ? "In cart" : "Not in cart")
                .accessibilityHint("Double-tap to change")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), \(item.detail)")
                .accessibilityValue(isChecked ? "On your list" : "")
        }
    }
}
