import SwiftUI

struct ItemPickerView: View {
    @EnvironmentObject private var calibration: DemoCalibration

    var body: some View {
        List {
            Section {
                ForEach(DemoItem.all.filter(\.recognizesByAppearance)) { ItemRow(item: $0) }
            } header: {
                Text("By appearance · Apple Vision")
            } footer: {
                Text("Frame one item. No label needed.")
            }
            Section {
                ForEach(DemoItem.all.filter { !$0.recognizesByAppearance }) { ItemRow(item: $0) }
            } header: {
                Text("By label · OCR")
            } footer: {
                Text("Doritos and Oreo come in lookalike pairs to test the lead over a neighbor.")
            }
            Section("Calibration") {
                NavigationLink {
                    ScrollView { CalibrationPanel(calibration: calibration).padding() }
                        .navigationTitle("Calibration")
                } label: {
                    VStack(alignment: .leading) {
                        Text("Window, thresholds and monkey test")
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Item Recognition Test")
        .navigationDestination(for: DemoItem.self) { item in
            CameraDemoView(item: item, calibration: calibration)
        }
    }

    private var summary: String {
        let session = calibration.session
        return String(format: "%@ · %.1f–%.1f m · coverage %.0f%% · produce %.0f%%",
                      session.landmarkID, session.activateAfterMeters, session.deactivateAfterMeters,
                      session.matchCoverage * 100, session.produceScore * 100)
    }
}

private struct ItemRow: View {
    let item: DemoItem

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                Text(item.location + (item.visualClass.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
