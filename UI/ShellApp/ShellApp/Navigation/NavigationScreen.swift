import SwiftUI

/// Turn by turn through the store. Every instruction is also spoken and played on the watch, so
/// the screen is for whoever is helping, and for trying routes out with the simulated walk.
struct NavigationScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let navigator = model.navigator {
                    NavigationContent(navigator: navigator)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Navigation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End") { model.stopNavigation() }
                }
            }
        }
    }
}

private struct NavigationContent: View {
    let navigator: RouteNavigator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                Text(navigator.instruction)
                    .font(.title.bold())
                    .accessibilityAddTraits(.updatesFrequently)

                if navigator.phase == .walking {
                    Text("\(Int(navigator.metersLeft.rounded())) m to go")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(Theme.accentText)
                }

                if let note = navigator.trackingNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                StoreMapView(map: navigator.map, path: navigator.remainingPath,
                             stops: navigator.plan.stops.map(\.path))
                    .frame(height: 260)
                    .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))

                if navigator.phase == .atStop {
                    Button("Skip this stop") { navigator.skipStop() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityHint("Moves on without these items")
                }

                if navigator.isSimulated && navigator.phase != .finished {
                    simulation
                }
            }
            .padding(16)
        }
    }

    private var status: String {
        switch navigator.phase {
        case .walking: "Leg \(navigator.legIndex + 1) of \(navigator.legs.count)"
        case .atStop: "Stop \((navigator.activeStop?.id ?? 0) + 1)"
        case .wrongWay: "Off route"
        case .finished: "Done"
        }
    }

    private var simulation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulated walk")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Walk 1 m") { navigator.simulateWalk(1) }
                Button("To next point") { navigator.simulateWalkToNext() }
            }
            HStack(spacing: 8) {
                Button("Wrong turn") { navigator.simulateWrongTurn() }
                Button("Go back") { navigator.simulateGoBack() }
            }
            Text("At a stop, check the items off on the Shop screen or by voice to move on.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.bordered)
        .cardStyle()
    }
}
