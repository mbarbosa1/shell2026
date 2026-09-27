import AVFoundation
import SwiftUI

struct OnboardingPage {
    let symbol: String
    let title: String
    let body: String

    /// What the voice reads. Recordings in the agent's voice go in the app as onboarding_0.mp3, onboarding_1.mp3, …
    var spoken: String { "\(title). \(body)" }

    static let all = [
        OnboardingPage(symbol: "cart", title: "Welcome to Mira",
                       body: "Mira helps you shop by voice. Tell it what you need and it keeps your list."),
        OnboardingPage(symbol: "camera.viewfinder", title: "Your shopping device",
                       body: "Put your phone on the cart mount. The camera shows what's in front of you."),
        OnboardingPage(symbol: "waveform", title: "Just talk",
                       body: "Say “add oat milk”, “remove bananas” or “open camera” any time."),
        OnboardingPage(symbol: "checkmark.circle", title: "You're all set",
                       body: "Tap Get started, or say it, to open your list."),
    ]

    // What Mira says about the microphone. Recordings: onboarding_ask_mic.mp3, onboarding_mic_on.mp3, onboarding_mic_off.mp3.
    static let askForMic = "To talk to me, tap Allow microphone on the screen, then tap Allow."
    static let micOn = "Great, I can hear you now. Say next when you're ready."
    static let micOff = "The microphone is off. You can keep going with the buttons, or turn it on in Settings."
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var narrator = Narrator()
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    /// Moves VoiceOver to the page title when the page changes, so it reads the new page.
    @AccessibilityFocusState private var isTitleFocused: Bool

    private let pages = OnboardingPage.all
    private var index: Int { model.onboardingPage }
    private var page: OnboardingPage { pages[index] }
    private var isLastPage: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls if the user has large text turned on.
            ScrollView {
                pageContent
                    .id(index)
                    .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)

            buttons
        }
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background.ignoresSafeArea())
        .listeningGlow(model.isListening)
        .task { welcome() }
        .onChange(of: model.onboardingPage) { isTitleFocused = true }
        .onChange(of: voiceOverOn) { _, isOn in
            if isOn { narrator.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings: the user may have turned the mic on there.
            guard phase == .active else { return }
            let wasAllowed = micPermission == .granted
            micPermission = AVAudioApplication.shared.recordPermission
            if !wasAllowed && micPermission == .granted { micTurnedOn() }
        }
        .onDisappear { narrator.stop() }
    }

    // MARK: Page

    private var pageContent: some View {
        VStack(spacing: 20) {
            Image(systemName: page.symbol)
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Theme.accentText)
                .accessibilityHidden(true) // decoration only

            Text(page.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(page.title). Page \(index + 1) of \(pages.count)")
                .accessibilityFocused($isTitleFocused)

            Text(page.body)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)

            if let voiceStatus {
                Text(voiceStatus)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentText)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }

    /// Tells the user whether they can talk. Hidden with VoiceOver, since the agent is off then.
    private var voiceStatus: String? {
        guard !voiceOverOn else { return nil }
        if let error = model.voiceError { return error }
        guard model.isListening else { return nil }
        return isLastPage ? "Listening. Say “get started”." : "Listening. Say “next” or “back”."
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            if index == 0 && !voiceOverOn && micPermission == .undetermined {
                Button("Allow microphone") { Task { await allowMicrophone() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Lets you move through this guide and shop by voice")
                Button("Not now") { go(to: 1) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Keeps going with buttons instead of voice")
            } else if isLastPage {
                Button("Get started", action: finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Finishes setup and opens your shopping list")
            } else {
                Button("Next") { go(to: index + 1) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Goes to page \(index + 2) of \(pages.count)")
            }

            if micPermission == .denied && !voiceOverOn {
                Button("Turn on microphone in Settings") {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Opens Settings. Come back to keep going.")
            }

            HStack(spacing: 10) {
                if index > 0 {
                    Button("Back") { go(to: index - 1) }
                        .accessibilityHint("Goes to page \(index) of \(pages.count)")
                }
                if !isLastPage {
                    Button("Skip", action: finish)
                        .accessibilityHint("Skips the guide and opens your shopping list")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: Voice

    /// Runs when onboarding opens: Mira says the welcome, then what to do about the microphone.
    private func welcome() {
        guard !voiceOverOn else { return } // VoiceOver reads the page itself
        // Mira can still be connected, e.g. from a shopping trip before "Replay onboarding". Hang
        // up so she doesn't hear the welcome and talk over it; `micTurnedOn` starts her after.
        if model.isVoiceConnected { Task { await model.setListening(false) } }
        narrator.speak(pages[0].spoken, clip: "onboarding_0") {
            switch micPermission {
            case .granted: micTurnedOn()
            case .undetermined: narrator.speak(OnboardingPage.askForMic, clip: "onboarding_ask_mic")
            default: narrator.speak(OnboardingPage.micOff, clip: "onboarding_mic_off")
            }
        }
    }

    private func allowMicrophone() async {
        narrator.stop()
        let granted = await AVAudioApplication.requestRecordPermission()
        micPermission = AVAudioApplication.shared.recordPermission
        if granted {
            micTurnedOn()
        } else {
            narrator.speak(OnboardingPage.micOff, clip: "onboarding_mic_off")
        }
    }

    /// Says the mic is on, then starts the agent. Starting it after the narrator finishes
    /// stops the agent from hearing the narrator and replying.
    private func micTurnedOn() {
        guard !voiceOverOn else { return }
        narrator.speak(OnboardingPage.micOn, clip: "onboarding_mic_on") {
            Task { await model.setListening(true) }
        }
    }

    /// Changes page from a button tap and reads the new page aloud.
    private func go(to newIndex: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut) {
            _ = model.showOnboardingPage(newIndex)
        }
        guard !voiceOverOn else { return } // VoiceOver reads the new title instead

        // Mute the agent while the narrator reads, so it doesn't hear the narrator and reply.
        let muteAgent = model.isVoiceConnected
        if muteAgent { Task { await model.setListening(false) } }
        narrator.speak(pages[newIndex].spoken, clip: "onboarding_\(newIndex)") {
            if muteAgent { Task { await model.setListening(true) } }
        }
    }

    private func finish() {
        narrator.stop()
        model.finishOnboarding()
    }
}

#Preview {
    OnboardingView()
        .environment(AppModel.preview)
        .preferredColorScheme(.dark)
}