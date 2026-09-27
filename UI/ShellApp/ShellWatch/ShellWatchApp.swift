import SwiftUI

@main
struct ShellWatchApp: App {
    @State private var receiver = WatchReceiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(receiver.text)
                        .font(.title3.bold())
                        .accessibilityAddTraits(.updatesFrequently)
                    if !receiver.isConnected {
                        Text("Not connected to your iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { receiver.activate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { receiver.keepRunning() }
            }
        }
    }
}
