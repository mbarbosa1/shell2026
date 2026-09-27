import SwiftData
import SwiftUI

@main
struct ShellAppApp: App {
    private let container: ModelContainer
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase // NEW: is the app open, in the background, etc.

    init() {
        do {
            container = try GroceryDatabase.container()
        } catch {
            fatalError("Couldn't open the grocery database: \(error)")
        }
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.hasOnboarded {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
            // iOS posts this whenever VoiceOver is switched on or off.
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                Task { await model.voiceOverChanged() }
            }
            // NEW: runs when the app opens and each time you come back to it (e.g. from Settings).
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { model.checkReplayOnboardingSetting() }
            }
        }
        .modelContainer(container)
    }
}