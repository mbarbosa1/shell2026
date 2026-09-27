import Foundation
import ItemRecognition

/// Values that feed `ActivationGate` and the match policies, for hand and monkey testing.
///
/// Two kinds of values, because the gate loads its rule once per session:
/// - `Session` (window and thresholds) takes effect when a scan starts or restarts.
/// - `Live` (reported landmark, metres, reliable, pause) takes effect on the next frame.
@MainActor
final class DemoCalibration: ObservableObject {
    struct Session: Equatable {
        var landmarkID: String
        var activateAfterMeters: Double
        var deactivateAfterMeters: Double
        /// Share of the grocery-list words OCR must read (`RecognitionPolicy.minimumQueryScore`).
        var matchCoverage: Double
        /// Apple Vision score the produce label must reach (`VisualRecognitionPolicy.minimumScore`).
        var produceScore: Double
    }

    struct Live: Equatable {
        var passedLandmarkID: String?
        var meters: Double
        var reliable: Bool
        var paused: Bool
    }

    static let defaultSession = Session(landmarkID: "demo-aisle", activateAfterMeters: 3, deactivateAfterMeters: 20,
                                        matchCoverage: 0.65, produceScore: 0.30)

    @Published var session = defaultSession {
        didSet {
            // The gate treats a window with end < start as an invalid rule; keep the sliders consistent.
            if session.deactivateAfterMeters < session.activateAfterMeters {
                session.deactivateAfterMeters = session.activateAfterMeters
            }
        }
    }
    @Published var meters = 5.0
    @Published var reportsWrongLandmark = false
    @Published var reliable = true
    @Published var paused = false

    @Published private(set) var monkeyEnabled = false
    @Published private(set) var monkeyTicks = 0
    /// Newest first, capped so a long run does not grow without bound.
    @Published private(set) var monkeyLog: [String] = []
    private var monkeyTask: Task<Void, Never>?

    var live: Live {
        Live(passedLandmarkID: reportsWrongLandmark ? "other-aisle" : session.landmarkID,
             meters: meters, reliable: reliable, paused: paused)
    }

    /// Upper end of the metres slider: a little past the window so `thresholdPassed` is reachable.
    var meterRange: ClosedRange<Double> { 0...(session.deactivateAfterMeters + 5) }

    func rule(for item: DemoItem) -> DetectionActivationRuleSnapshot {
        DetectionActivationRuleSnapshot(targetItemID: item.id, landmarkID: session.landmarkID,
                                        activateAfterMeters: session.activateAfterMeters,
                                        deactivateAfterMeters: session.deactivateAfterMeters)
    }

    var recognitionPolicy: RecognitionPolicy { RecognitionPolicy(minimumQueryScore: Float(session.matchCoverage)) }

    /// Same shape as `VisualRecognitionPolicy.appleVisionProduce`, with the score from the slider.
    var visualPolicy: VisualRecognitionPolicy {
        VisualRecognitionPolicy(minimumScore: Float(session.produceScore), minimumMargin: 0.1)
    }

    func resetLive() {
        meters = 5
        reportsWrongLandmark = false
        reliable = true
        paused = false
    }

    // MARK: - Monkey testing

    func setMonkey(_ enabled: Bool) {
        monkeyTask?.cancel()
        monkeyTask = nil
        monkeyEnabled = enabled
        guard enabled else { log("Monkey stopped after \(monkeyTicks) ticks"); return }
        monkeyTicks = 0
        monkeyLog = []
        monkeyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.monkeyStep()
            }
        }
    }

    /// One random change per second. Metres mostly walk forward and back, sometimes jump.
    /// Pause, unreliable and wrong landmark are each redrawn every tick with a 10% chance of being
    /// on, so they appear often but never stick for long.
    private func monkeyStep() {
        monkeyTicks += 1
        let range = meterRange
        let jump = Double.random(in: 0..<1) < 0.1
        let next = jump ? Double.random(in: range) : meters + Double.random(in: -2...3)
        meters = (min(max(next, range.lowerBound), range.upperBound) * 10).rounded() / 10
        paused = Double.random(in: 0..<1) < 0.1
        reliable = Double.random(in: 0..<1) >= 0.1
        reportsWrongLandmark = Double.random(in: 0..<1) < 0.1

        var flags: [String] = []
        if paused { flags.append("paused") }
        if !reliable { flags.append("unreliable") }
        if reportsWrongLandmark { flags.append("wrong landmark") }
        let move = jump ? "jump" : "walk"
        log("#\(monkeyTicks) \(move) → \(String(format: "%.1f", meters)) m" + (flags.isEmpty ? "" : " · " + flags.joined(separator: ", ")))
    }

    private func log(_ line: String) {
        print("[ItemRecognition] Monkey: \(line)")
        monkeyLog.insert(line, at: 0)
        if monkeyLog.count > 20 { monkeyLog.removeLast() }
    }
}
