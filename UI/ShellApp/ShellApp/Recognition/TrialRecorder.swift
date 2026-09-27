import Foundation
import ItemRecognition
import Observation

/// Baseline trials for testers (`ItemRecognition/Baseline/README.md`), in the same CSV the Demo
/// writes. On only in Debug builds with "Tester mode" switched on in the iPhone Settings app.
///
/// Every item scan is one trial: at a stop on a real walk (`walk`), or started from the Trials
/// screen with detection forced on (`testScan`). The tester says what's in view (`setup`) before
/// it starts; `ItemScanner` feeds it and ends it (accepted, stopped, timed out, or an error).
@MainActor
@Observable
final class TrialRecorder {
    enum Mode: String {
        /// At a stop on a real walk: activation by distance is measured too.
        case walk
        /// From the Trials screen, detection on from the start: recognition only.
        case testScan
    }

    /// Tester mode is on and this is a Debug build.
    private(set) var isEnabled = false
    /// What's in view and under what conditions, declared before the scan starts.
    var setup = BaselineSetup()
    /// OCR language correction, tried both ways in the baseline. Only applies in tester mode.
    var languageCorrection = true
    /// The trial in progress.
    private(set) var current: BaselineTrial?
    private(set) var trialCount = 0
    /// "Trial 4: target · accepted · correct", or why the last one couldn't be saved.
    private(set) var lastSummary: String?

    let fileURL = URL.documentsDirectory.appending(path: "baseline-trials.csv")

    init() {
        trialCount = BaselineCSV.count(at: fileURL)
        refreshEnabled()
    }

    /// Language correction for the next scan: the tester's choice in tester mode, on otherwise.
    var usesLanguageCorrection: Bool { isEnabled ? languageCorrection : true }

    /// Reads the Settings app switch. Call when the app comes to the front.
    func refreshEnabled() {
        #if DEBUG
        isEnabled = UserDefaults.standard.bool(forKey: "testerMode")
        #else
        isEnabled = false
        #endif
    }

    func begin(_ target: ScanTarget, mode: Mode) {
        guard isEnabled else { return }
        let appearance = target.catalog.recognizesByAppearance
        current = BaselineTrial(
            setup: setup, targetTCIN: target.tcin, targetTitle: target.productTitle,
            listEntry: target.query.displayName,
            path: appearance ? (CloudAssistConfig.endpoint == nil ? "appleVision" : "gemini") : "ocr",
            coverage: Double(RecognitionPolicy().minimumQueryScore),
            produceScore: Double(VisualRecognitionPolicy.appleVisionProduce.minimumScore),
            app: "shellapp", mode: mode.rawValue, languageCorrection: usesLanguageCorrection)
    }

    func record(_ update: RecognitionUpdate, neighbor: String?) { current?.record(update, neighbor: neighbor) }
    func asked(_ level: RecognitionMatchLevel?) { current?.asked(level) }
    func rejected() { current?.rejections += 1 }
    /// The one-minute notice came while the question was open.
    func timedOut() { current?.timedOut = true }

    /// Saves the trial in progress, if any. A stop after the one-minute notice counts as timed out.
    func finish(_ outcome: BaselineTrial.Outcome) {
        guard let trial = current else { return }
        current = nil
        let outcome = outcome == .stopped && trial.timedOut ? .timedOut : outcome
        do {
            try BaselineCSV.append(trial, outcome: outcome, to: fileURL)
            trialCount += 1
            lastSummary = "Trial \(trialCount): \(trial.setup.kind.rawValue) · \(outcome.rawValue) · "
                + (trial.correct(outcome) ? "correct" : "wrong")
                + (trial.tally.blocker.map { " · stopped mostly at \($0.name)" } ?? "")
        } catch {
            lastSummary = "Couldn't save the trial: \(error.localizedDescription)"
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        trialCount = 0
        lastSummary = nil
    }
}
