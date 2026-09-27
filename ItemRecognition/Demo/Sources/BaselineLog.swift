import Foundation
import ItemRecognition
import SwiftUI

// `BaselineSetup`, `BaselineTrial` and the CSV writer live in ItemRecognition
// (Evaluation/BaselineTrial.swift), shared with ShellApp.

/// Appends one CSV row per finished trial to Documents/baseline-trials.csv.
@MainActor
final class BaselineLog: ObservableObject {
    @Published var recording = false
    @Published var setup = BaselineSetup()
    @Published private(set) var trialCount = 0
    @Published private(set) var lastSummary: String?

    let fileURL = URL.documentsDirectory.appending(path: "baseline-trials.csv")

    init() { trialCount = BaselineCSV.count(at: fileURL) }

    var hasTrials: Bool { trialCount > 0 }

    func save(_ trial: BaselineTrial, outcome: BaselineTrial.Outcome) {
        do {
            try BaselineCSV.append(trial, outcome: outcome, to: fileURL)
            trialCount += 1
            let verdict = trial.correct(outcome) ? "correct" : "wrong"
            lastSummary = "Trial \(trialCount): \(trial.setup.kind.rawValue) · \(outcome.rawValue) · \(verdict)"
                + (trial.tally.blocker.map { " · stopped mostly at \($0.name)" } ?? "")
            print("[ItemRecognition] Baseline \(lastSummary ?? "")")
        } catch {
            lastSummary = "Could not save the trial: \(error.localizedDescription)"
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        trialCount = 0
        lastSummary = nil
    }

}

/// Trial setup shown above the results while recording. Locked while the camera runs.
struct BaselineSetupCard: View {
    @ObservedObject var log: BaselineLog
    let item: DemoItem
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("1. What is in view").font(.headline)
                Spacer()
                Text("Tester · \(log.trialCount) saved").font(.caption).foregroundStyle(.secondary)
            }
            Picker("In view", selection: $log.setup.kind) {
                ForEach(BaselineSetup.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(log.setup.kind == .target ? item.title : "What is in view, e.g. Doritos Cool Ranch",
                      text: $log.setup.shown)
                .textFieldStyle(.roundedBorder)
            HStack {
                menu("Place", $log.setup.place)
                menu("Light", $log.setup.light)
            }
            HStack {
                menu("Distance", $log.setup.distance)
                menu("Motion", $log.setup.motion)
            }
            TextField("Notes (shelf, packaging, angle)", text: $log.setup.notes).textFieldStyle(.roundedBorder)
            Text(isRunning ? "Recording. Answer the question if asked, then tap Stop to save."
                           : "Set what is in view, then tap Start. Stop saves the trial.")
                .font(.caption).foregroundStyle(.secondary)
            if let summary = log.lastSummary { Text(summary).font(.caption.weight(.semibold)) }
        }
        .disabled(isRunning)
        .card(Color.purple.opacity(0.1))
    }

    private func menu<Value: RawRepresentable & CaseIterable & Identifiable & Hashable>(
        _ title: String, _ selection: Binding<Value>) -> some View where Value.RawValue == String, Value.AllCases: RandomAccessCollection {
        Picker(title, selection: selection) {
            ForEach(Value.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
