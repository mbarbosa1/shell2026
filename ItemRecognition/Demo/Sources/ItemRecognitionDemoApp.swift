import SwiftUI

@main
struct ItemRecognitionDemoApp: App {
    @StateObject private var calibration = DemoCalibration()

    var body: some Scene {
        WindowGroup {
            NavigationStack { ItemPickerView() }
                .environmentObject(calibration)
        }
    }
}
