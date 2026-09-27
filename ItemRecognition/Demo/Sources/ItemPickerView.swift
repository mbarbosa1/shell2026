import ItemRecognition
import SwiftUI

struct ItemPickerView: View {
    @EnvironmentObject private var calibration: DemoCalibration
    @EnvironmentObject private var baseline: BaselineLog
    @AppStorage(DemoScanConfiguration.endpointKey) private var endpoint = ""
    @AppStorage(DemoScanConfiguration.tokenKey) private var token = ""
    @State private var confirmClear = false
    @State private var connection: String?
    @State private var checking = false

    var body: some View {
        List {
            Section {
                TextField("http://<mac-name>.local:8787/v1/produce-label", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Proxy token (not the Gemini key)", text: $token)
                Button(checking ? "Testing…" : "Test connection") { Task { await testConnection() } }
                    .disabled(checking || endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                if let connection {
                    Text(connection).font(.caption)
                }
            } header: {
                Text("1. Gemini proxy")
            } footer: {
                Text("Tester only. Produce uses Apple Vision first; Gemini helps after 5 s at the item, 2 calls per item at most. The API key stays on the Mac. The test uses no Gemini call and does not check the token.")
            }
            Section {
                Toggle("Record baseline trials", isOn: $baseline.recording)
                if baseline.hasTrials {
                    ShareLink(item: baseline.fileURL) {
                        Label("Export \(baseline.trialCount) trials (CSV)", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete saved trials", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("2. Record baseline")
            } footer: {
                Text("On the next screen, set what is in view and metres, then Start. Each Start→Stop is one CSV row.")
            }
            Section {
                ForEach(DemoItem.all.filter(\.recognizesByAppearance)) { ItemRow(item: $0) }
            } header: {
                Text("3. Pick item · " + (endpoint.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "appearance · Apple Vision" : "appearance · Apple Vision, then Gemini"))
            } footer: {
                Text("Frame one item. No label needed.")
            }
            Section {
                ForEach(DemoItem.all.filter { !$0.recognizesByAppearance }) { ItemRow(item: $0) }
            } header: {
                Text("3. Pick item · label · OCR")
            } footer: {
                Text("Doritos and Oreo come in lookalike pairs to test the lead over a neighbor.")
            }
            Section {
                NavigationLink {
                    ScrollView { CalibrationPanel(calibration: calibration).padding() }
                        .navigationTitle("Tester calibration")
                } label: {
                    VStack(alignment: .leading) {
                        Text("Window, thresholds and monkey test")
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tester calibration")
            } footer: {
                Text("Navigation stand-in. Not shown to the shopper. Defaults (5 m in 3–20 m) are already Active.")
            }
        }
        .navigationTitle("Item Recognition Test")
        .navigationDestination(for: DemoItem.self) { item in
            CameraDemoView(item: item, calibration: calibration, baseline: baseline, endpointText: endpoint, token: token)
        }
        .confirmationDialog("Delete all \(baseline.trialCount) saved trials?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { baseline.clear() }
        }
    }

    private func testConnection() async {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else {
            connection = "Not a valid address. Use http://<mac-name>.local:8787/v1/produce-label"
            return
        }
        checking = true
        defer { checking = false }
        do {
            let status = try await CloudProxyStatus.check(url)
            connection = status.mock ? "Connected · mock proxy (fixed label, no Gemini cost)"
                                     : "Connected · Gemini \(status.model)"
        } catch {
            connection = "Not reachable: \(error.localizedDescription)"
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
