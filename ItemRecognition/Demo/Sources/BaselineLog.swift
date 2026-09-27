import Foundation
import ItemRecognition
import SwiftUI
import UIKit

/// What the tester puts in front of the camera and under what conditions. Declared
/// before Start, so a trial's expected answer is fixed before any result is seen.
struct BaselineSetup: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        /// The selected item itself: success is being asked, then answering Yes.
        case target
        /// A near neighbor (Cool Ranch for Nacho Cheese, potato for onion): success is never being asked.
        case lookalike
        /// Anything else: another product, empty shelf, hand. Success is never being asked.
        case negative
        var id: String { rawValue }
    }
    enum Place: String, CaseIterable, Identifiable { case store, home; var id: String { rawValue } }
    enum Light: String, CaseIterable, Identifiable { case normal, dim, glare, backlit; var id: String { rawValue } }
    enum Distance: String, CaseIterable, Identifiable {
        case close = "close <30cm", arm = "arm 30-60cm", far = "far >60cm"
        var id: String { rawValue }
    }
    enum Motion: String, CaseIterable, Identifiable { case still, walking; var id: String { rawValue } }

    var kind: Kind = .target
    /// What is actually in view, in the tester's words: "Doritos Cool Ranch 9.25oz", "empty shelf".
    var shown = ""
    var place: Place = .store
    var light: Light = .normal
    var distance: Distance = .arm
    var motion: Motion = .still
    var notes = ""
}

/// One scan attempt from Start to Stop, attributed to pipeline stages.
struct BaselineTrial {
    enum Outcome: String { case accepted, stopped, timedOut, error }

    let setup: BaselineSetup
    let item: DemoItem
    /// The grocery-list words the scan matched against.
    let listEntry: String
    let path: String
    let coverage: Double
    let produceScore: Double
    let started = Date()
    var tally = RecognitionStageTally()
    var asks = 0
    var rejections = 0
    var firstAsk: TimeInterval?
    var askedLevel: RecognitionMatchLevel?
    var timedOut = false
    var maxMatch = 0
    var maxScore = 0
    var neighbors: [String: Int] = [:]
    var lastRead = ""

    mutating func record(_ update: RecognitionUpdate, neighbor: DemoItem?) {
        if update.advanceNotice != nil { timedOut = true }
        guard let outcome = update.stageOutcome else { return }
        tally.record(outcome)
        if let result = update.result {
            maxMatch = max(maxMatch, Int((result.matchConfidence * 100).rounded()))
            maxScore = max(maxScore, Int((result.score * 100).rounded()))
        }
        if let neighbor, neighbor.id != item.id { neighbors[neighbor.title, default: 0] += 1 }
        let read = update.observation?.candidates.map(\.rawText).joined(separator: " ")
            ?? update.result?.visualEvidence?.classifications.prefix(3)
                .map { "\($0.identifier)=\(Int(($0.score * 100).rounded()))%" }.joined(separator: " ")
        if let read, !read.isEmpty { lastRead = read }
    }

    mutating func asked(_ level: RecognitionMatchLevel?) {
        asks += 1
        if firstAsk == nil { firstAsk = Date().timeIntervalSince(started) }
        if askedLevel == nil { askedLevel = level }
    }

    /// A target trial succeeds when the shopper accepts; any other trial when it never asks.
    func correct(_ outcome: Outcome) -> Bool {
        setup.kind == .target ? outcome == .accepted : asks == 0
    }

    @MainActor func row(_ outcome: Outcome) -> [String] {
        let counts = RecognitionStage.allCases.map { String(tally.stageCounts[$0] ?? 0) }
        let seconds = { (value: TimeInterval?) in value.map { String(format: "%.1f", $0) } ?? "" }
        return [
            ISO8601DateFormatter().string(from: started), BaselineLog.deviceModel, UIDevice.current.systemVersion,
            setup.place.rawValue, setup.light.rawValue, setup.distance.rawValue, setup.motion.rawValue,
            setup.kind.rawValue, item.tcin, item.title,
            setup.shown.isEmpty && setup.kind == .target ? item.title : setup.shown, path,
            String(format: "%.2f", coverage), String(format: "%.2f", produceScore),
            outcome.rawValue, correct(outcome) ? "yes" : "no", String(asks), String(rejections),
            askedLevel?.rawValue ?? "", seconds(firstAsk), seconds(Date().timeIntervalSince(started)),
            String(tally.frames), tally.furthest?.name ?? "", tally.blocker?.name ?? "",
        ] + counts + [
            tally.topReasons(3).map { "\($0.reason) \($0.count)" }.joined(separator: "; "),
            String(maxScore), String(maxMatch),
            neighbors.max { $0.value < $1.value }?.key ?? "", lastRead, setup.notes, listEntry,
        ]
    }

    static let header = [
        "started", "device", "ios", "place", "light", "distance", "motion",
        "kind", "target_tcin", "target_title", "shown", "path", "coverage_threshold", "produce_threshold",
        "outcome", "correct", "asks", "rejections", "asked_level", "seconds_to_first_ask", "seconds",
        "frames", "furthest_stage", "blocker",
    ] + RecognitionStage.allCases.map { "frames_" + $0.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_") }
      + ["top_reasons", "max_score_pct", "max_match_pct", "leading_neighbor", "last_read", "notes", "list_entry"]
}

/// Appends one CSV row per finished trial to Documents/baseline-trials.csv.
@MainActor
final class BaselineLog: ObservableObject {
    @Published var recording = false
    @Published var setup = BaselineSetup()
    @Published private(set) var trialCount = 0
    @Published private(set) var lastSummary: String?

    let fileURL = URL.documentsDirectory.appending(path: "baseline-trials.csv")

    init() { trialCount = max(0, ((try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n").count ?? 1) - 1) }

    var hasTrials: Bool { trialCount > 0 }

    func save(_ trial: BaselineTrial, outcome: BaselineTrial.Outcome) {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        var text = exists ? "" : Self.line(BaselineTrial.header)
        text += Self.line(trial.row(outcome))
        do {
            if exists {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try Data(text.utf8).write(to: fileURL, options: .atomic)
            }
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

    private static func line(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",") + "\n"
    }

    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
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
