import SwiftUI

@main
struct ItemRecognitionDemoApp: App {
    @StateObject private var calibration = DemoCalibration()
    @StateObject private var baseline = BaselineLog()

    var body: some Scene {
        WindowGroup {
            NavigationStack { ItemPickerView() }
                .environmentObject(calibration)
                .environmentObject(baseline)
        }
    }
}
