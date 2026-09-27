#if DEBUG
import ItemRecognition
import SwiftUI

/// Tester mode's Trials screen (Debug builds): say what will be in view before a scan, try OCR
/// language correction both ways, start a test scan, and export the trials CSV for
/// `ItemRecognition/Baseline/summarize.py`. The protocol is in `ItemRecognition/Baseline/README.md`.
struct TrialsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var problem: String?

    var body: some View {
        @Bindable var trials = model.trials

        NavigationStack {
            Form {
                Section {
                    Picker("In view", selection: $trials.setup.kind) {
                        ForEach(BaselineSetup.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(trials.setup.kind == .target ? "The item itself" : "What is in view, e.g. Doritos Cool Ranch",
                              text: $trials.setup.shown)
                    menu("Place", $trials.setup.place)
                    menu("Light", $trials.setup.light)
                    menu("Distance", $trials.setup.distance)
                    menu("Motion", $trials.setup.motion)
                    TextField("Notes (shelf, packaging, angle)", text: $trials.setup.notes)
                } header: {
                    Text("1. What will be in view")
                } footer: {
                    Text("Set this before the scan starts. It applies to every trial until you change it.")
                }

                Section {
                    Toggle("OCR language correction", isOn: $trials.languageCorrection)
                } footer: {
                    Text("Applies from the next item. Run the label items both ways.")
                }

                CloudAssistSettingsSection()

                Section {
                    let items = model.items.filter { $0.tcin != nil }
                    if items.isEmpty {
                        Text("Add items to your list first.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(items) { item in
                        Button {
                            problem = model.startTestScan(item)
                            if problem == nil { dismiss() }
                        } label: {
                            LabeledContent(item.name, value: item.location ?? "")
                        }
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.orange)
                    }
                } header: {
                    Text("2. Test scan an item")
                } footer: {
                    Text("Scans right away with detection on, without walking there, on a phone only. Yes saves the trial and leaves your list alone. On a real walk, every stop's scan is a trial too.")
                }

                Section {
                    if let summary = trials.lastSummary {
                        Text(summary)
                    }
                    if trials.trialCount > 0 {
                        ShareLink(item: trials.fileURL) {
                            Label("Export \(trials.trialCount) trials (CSV)", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete saved trials", role: .destructive) { confirmClear = true }
                    } else {
                        Text("No trials saved yet.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    Text("3. Saved trials")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Trials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete all \(trials.trialCount) saved trials?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { trials.clear() }
            }
        }
    }

    private func menu<Value: RawRepresentable & CaseIterable & Identifiable & Hashable>(
        _ title: String, _ selection: Binding<Value>
    ) -> some View where Value.RawValue == String, Value.AllCases: RandomAccessCollection {
        Picker(title, selection: selection) {
            ForEach(Value.allCases) { Text($0.rawValue).tag($0) }
        }
    }
}
#endif
