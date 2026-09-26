import SwiftData
import SwiftUI

@main
struct ShellAppApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

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
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}
