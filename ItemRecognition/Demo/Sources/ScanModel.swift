import AVFoundation
import ItemRecognition
import SwiftUI

/// Which way to move the phone, from the latest processed frame. The library's
/// `RecognitionGuidance` never says "centered": no guidance with an item in view means centered.
enum PositionAdvice: Equatable {
    case move(RecognitionGuidance)
    case centered
    /// Nothing usable in view; the frame assessor's plain-language reason.
    case hint(String)

    init?(_ update: RecognitionUpdate) {
        if update.awaitingVerdict { return nil }
        if let guidance = update.guidance { self = .move(guidance); return }
        let itemInView = update.assessment?.objectRegion != nil
            || update.observation?.candidates.isEmpty == false
        if itemInView { self = .centered; return }
        guard let assessment = update.assessment else { return nil }
        self = .hint(assessment.message)
    }

    var symbol: String {
        switch self {
        case .centered: return "scope"
        case .hint: return "viewfinder"
        case .move(let guidance):
            switch guidance {
            case .moveLeft: return "arrow.left.circle.fill"
            case .moveRight: return "arrow.right.circle.fill"
            case .moveCloser: return "arrow.up.circle.fill"
            case .moveBack: return "arrow.down.circle.fill"
            case .keepWalking: return "figure.walk"
            case .holdSteady: return "hand.raised.fill"
            case .showLabel: return "arrow.triangle.2.circlepath"
            }
        }
    }

    var text: String {
        switch self {
        case .centered: return "Centered – hold still"
        case .hint(let message): return message
        case .move(let guidance): return guidance.message
        }
    }

    var isCentered: Bool { self == .centered }
}

@MainActor
final class ScanModel: ObservableObject {
    let item: DemoItem
    let calibration: DemoCalibration
    let baseline: BaselineLog
    private var trial: BaselineTrial?
    private let endpointText: String
    private let token: String
    private(set) var configuration: DemoScanConfiguration

    /// The shopper's grocery-list entry; the words the package must show. Editable before Start.
    @Published var listEntry: String
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Camera not started."
    @Published private(set) var permissionDenied = false
    /// The session values the running coordinator was built with.
    @Published private(set) var appliedSession: DemoCalibration.Session?

    @Published private(set) var gate: ActivationDecision?
    @Published private(set) var position: PositionAdvice?
    @Published private(set) var modeMessage: String
    @Published private(set) var geminiModel: String
    /// Gemini calls and last answer for this item scan; nil without a proxy.
    @Published private(set) var geminiUsage: CloudAssistUsage?
    private var produceClassifier: ProduceCategoryClassifier?

    /// Mean Vision confidence of the latest OCR lines, 0…100: read quality, not identity.
    @Published private(set) var ocrPercent: Int?
    /// Evidence for the target on the latest frame: grocery-list word coverage (OCR) or label score (visual).
    @Published private(set) var scorePercent: Int?
    /// `ItemRecognitionResult.matchConfidence`, smoothed over recent frames.
    @Published private(set) var matchPercent: Int?
    @Published private(set) var resultStatus: ItemRecognitionResult.Status?
    /// Set once confirmed: `.category` means only the produce class matched.
    @Published private(set) var matchLevel: RecognitionMatchLevel?
    @Published private(set) var evidenceSource: RecognitionEvidenceSource?
    /// The preset item whose words scored highest on the latest frame; can be a lookalike neighbor.
    @Published private(set) var bestMatch: DemoItem?
    /// Where the latest processed frame stopped, e.g. cropping · textTooSmall.
    @Published private(set) var stage: RecognitionStageOutcome?
    @Published private(set) var verdictPrompt: String?
    /// The library's own sentence, e.g. `Read "Reduced Fat Milk". Partly matches (35%).`
    @Published private(set) var readSummary: String?

    @Published private(set) var lines: [RecognizedTextCandidate] = []
    @Published private(set) var labels: [VisualClassification] = []

    @Published private(set) var awaitingVerdict = false
    @Published private(set) var insight = ""
    @Published private(set) var advanceNotice: String?
    @Published private(set) var frameMilliseconds: Int?
    private var lastLogged: String?

    init(item: DemoItem, calibration: DemoCalibration, baseline: BaselineLog, endpointText: String = "", token: String = "") {
        self.item = item
        self.calibration = calibration
        self.baseline = baseline
        self.endpointText = endpointText
        self.token = token
        listEntry = item.listEntry
        let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { url in
            (url.scheme == "http" || url.scheme == "https") && url.host != nil ? url : nil
        }
        configuration = DemoScanConfiguration(item: item, endpoint: endpoint,
                                              token: token.isEmpty ? nil : token,
                                              geminiModel: DemoScanConfiguration.defaultModel)
        geminiModel = configuration.geminiModel
        modeMessage = (item.recognizesByAppearance
                       ? RecognitionModeNotice.appleVision
                       : .ocrOnly).message
    }

    lazy var capture = DemoCameraCapture { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event) }
    }

    /// True when window or thresholds changed since this scan started.
    var needsRestart: Bool { appliedSession.map { $0 != calibration.session } ?? false }

    /// Threshold the current evidence must reach, for display next to the score.
    var thresholdPercent: Int {
        let session = appliedSession ?? calibration.session
        let appearance = evidenceSource.map { $0 == .visual } ?? item.recognizesByAppearance
        return Int(((appearance ? session.produceScore : session.matchCoverage) * 100).rounded())
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        status = "Requesting camera access…"
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard isRunning else { return } // The app may have left the foreground during the prompt.
        permissionDenied = !allowed
        guard allowed else {
            isRunning = false
            status = "Camera access is off. Enable it in Settings, then tap Start."
            return
        }
        clearResults()
        status = "Starting rear camera…"
        let session = calibration.session
        do {
            configuration = await DemoScanConfiguration.load(item: item, endpointText: endpointText, token: token)
            geminiModel = configuration.geminiModel
            // Produce uses Apple Vision first; with a proxy URL, Gemini helps after 5 s at the item
            // (2 calls per item). Packaged goods read the label only: a produce classifier cannot
            // tell one package from another.
            let classifier = item.recognizesByAppearance
                ? try ProduceCategoryClassifier(base: VisionImageClassifier(), cloud: configuration.labeler()) : nil
            produceClassifier = configuration.usesGemini ? classifier : nil
            let coordinator = try await RecognitionCoordinator(
                targetID: item.id,
                catalog: DemoCatalog(rule: calibration.rule(for: item)),
                policy: calibration.recognitionPolicy,
                visualClassifier: classifier,
                visualPolicy: calibration.visualPolicy,
                query: GroceryQuery(name: listEntry))
            guard isRunning else { await coordinator.stop(); return }
            appliedSession = session
            if baseline.recording {
                let path = item.recognizesByAppearance ? (configuration.usesGemini ? "gemini" : "appleVision") : "ocr"
                trial = BaselineTrial(setup: baseline.setup, item: item, listEntry: listEntry, path: path,
                                      coverage: session.matchCoverage, produceScore: session.produceScore)
            }
            capture.start(coordinator: coordinator, context: context(calibration.live))
            print("[ItemRecognition] Scan \(item.title) | list \"\(listEntry)\" | window \(session.activateAfterMeters)–\(session.deactivateAfterMeters) m after \(session.landmarkID) | coverage \(session.matchCoverage) | produce \(session.produceScore)")
        } catch {
            isRunning = false
            status = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        capture.stop()
        position = nil
        status = "Stopped. Last results are kept below."
        finishTrial(trial?.timedOut == true ? .timedOut : .stopped)
    }

    private func finishTrial(_ outcome: BaselineTrial.Outcome) {
        guard let finished = trial else { return }
        trial = nil
        baseline.save(finished, outcome: outcome)
    }

    func restart() async {
        stop()
        await start()
    }

    /// Sends new landmark progress to the running scan; the gate sees it on the next frame.
    func apply(_ live: DemoCalibration.Live) {
        guard isRunning else { return }
        capture.update(context: context(live))
    }

    func confirmInsight() {
        let accepted = insight
        capture.acceptInsight()
        awaitingVerdict = false
        verdictPrompt = nil
        finishTrial(.accepted)
        stop()
        status = "You confirmed \(accepted.isEmpty ? item.title : accepted)."
    }

    func negateInsight() {
        capture.rejectInsight()
        awaitingVerdict = false
        verdictPrompt = nil
        insight = ""
        trial?.rejections += 1
        status = "Not that. Looking again."
    }

    private func context(_ live: DemoCalibration.Live) -> RecognitionContext {
        RecognitionContext(
            targetItemID: item.id,
            landmarkProgress: LandmarkProgressObservation(
                timestamp: 0, passedLandmarkID: live.passedLandmarkID,
                metersPastLandmark: live.meters, isReliable: live.reliable),
            externalPause: live.paused)
    }

    private func clearResults() {
        gate = nil; position = nil; ocrPercent = nil; scorePercent = nil; matchPercent = nil
        resultStatus = nil; matchLevel = nil; evidenceSource = nil; bestMatch = nil; readSummary = nil
        stage = nil; verdictPrompt = nil
        lines = []; labels = []; awaitingVerdict = false; insight = ""; advanceNotice = nil
        frameMilliseconds = nil; lastLogged = nil; geminiUsage = nil
        modeMessage = (item.recognizesByAppearance
                       ? RecognitionModeNotice.appleVision
                       : .ocrOnly).message
    }

    private func receive(_ event: DemoCameraCapture.Event) {
        guard isRunning else { return }
        switch event {
        case .started:
            status = item.recognizesByAppearance
                ? (configuration.usesGemini ? "Scanning appearance. Gemini helps after 5 s at the item." : "Scanning appearance.")
                : "Scanning. Point at the label."
        case .update(let update, let milliseconds):
            apply(update, milliseconds: milliseconds)
        case .failure(let message):
            isRunning = false
            position = nil
            status = message
            finishTrial(.error)
            print("[ItemRecognition] Error: \(message)")
        }
    }

    private func apply(_ update: RecognitionUpdate, milliseconds: Double) {
        if let produceClassifier {
            Task { [weak self] in
                let usage = await produceClassifier.usage()
                self?.geminiUsage = usage
            }
        }
        gate = update.gate
        modeMessage = update.modeNotice.message
        // A settled answer repeats on every frame until answered: one question, one tallied frame.
        let repeated = update.awaitingVerdict && awaitingVerdict
        if update.awaitingVerdict && !repeated { trial?.asked(update.result?.matchLevel) }
        if !repeated {
            trial?.record(update, neighbor: DemoItem.named(update.result?.leadingItemID ?? update.result?.matchedItemID))
        } else if update.advanceNotice != nil {
            trial?.timedOut = true
        }
        awaitingVerdict = update.awaitingVerdict
        if update.awaitingVerdict { insight = update.insight ?? "" }
        verdictPrompt = update.verdictPrompt
        advanceNotice = update.advanceNotice ?? advanceNotice
        stage = update.stageOutcome ?? stage

        guard update.gate.isDetectionActive else {
            position = nil
            status = "Detection off. Change the position below to turn it on."
            return
        }
        frameMilliseconds = Int(milliseconds)
        status = "\(modeMessage) · \(Int(milliseconds)) ms per frame"
        position = PositionAdvice(update)

        if let observation = update.observation {
            lines = observation.candidates
            ocrPercent = observation.candidates.isEmpty ? nil : percent(
                observation.candidates.map(\.confidence).reduce(0, +) / Float(observation.candidates.count))
        }
        if let progress = update.progress { readSummary = progress }
        guard let result = update.result else { return }
        scorePercent = percent(result.score)
        matchPercent = percent(result.matchConfidence)
        resultStatus = result.status
        matchLevel = result.matchLevel
        evidenceSource = result.evidenceSource
        bestMatch = DemoItem.named(result.leadingItemID ?? result.matchedItemID)
        if let evidence = result.visualEvidence {
            labels = displayLabels(evidence)
            if let diagnostic = evidence.diagnostic, diagnostic.hasPrefix("Cloud model ") {
                geminiModel = String(diagnostic.dropFirst("Cloud model ".count))
            }
        }
        log(result)
    }

    /// The target's label always (even at 0%), other produce labels above 0%, and the
    /// background as `unknown(<raw Vision label>)`, highest first.
    private func displayLabels(_ evidence: VisualObservation) -> [VisualClassification] {
        let target = item.visualClass
        var shown = target.map { name in
            [evidence.classifications.first { $0.identifier == name } ?? VisualClassification(identifier: name, score: 0)]
        } ?? []
        shown += evidence.classifications
            .filter { $0.identifier != target && $0.identifier != "unknown" && $0.score > 0 }
            .prefix(4)
        if let unknown = evidence.classifications.first(where: { $0.identifier == "unknown" }), unknown.score > 0 {
            let name = evidence.backgroundLabel.map { "unknown (\($0))" } ?? "unknown"
            shown.append(VisualClassification(identifier: name, score: unknown.score))
        }
        return shown.sorted { $0.score > $1.score }
    }

    /// One console line per change of status, match decile, best match, or advice.
    private func log(_ result: ItemRecognitionResult) {
        let evidence = result.evidenceSource == .visual
            ? labels.map { "\($0.identifier)=\(percent($0.score))%" }.joined(separator: ", ")
            : lines.map(\.rawText).joined(separator: " | ")
        let signature = "\(result.status)|\((matchPercent ?? 0) / 10)|\(bestMatch?.tcin ?? "-")|\(position?.text ?? "-")"
        guard signature != lastLogged else { return }
        lastLogged = signature
        print("[ItemRecognition] \(result.status.rawValue) | match \(matchPercent ?? 0)% | score \(scorePercent ?? 0)% of \(thresholdPercent)% | best \(bestMatch?.title ?? "none") | \(position?.text ?? "no advice") | \(evidence)")
    }

    private func percent(_ value: Float) -> Int { Int((value * 100).rounded()) }
}

extension ActivationDecision {
    /// Plain-language gate state for the test screen.
    var summary: String {
        switch state {
        case .active: return "Active – recognizing"
        case .armed: return "Armed – " + reasonText
        case .waitingForLandmark: return "Waiting – " + reasonText
        case .suspended: return "Suspended – " + reasonText
        case .thresholdPassed: return "Passed – " + reasonText
        case .itemNotInStore: return "Off – item not carried here"
        }
    }

    var color: Color {
        switch state {
        case .active: return .green
        case .armed: return .yellow
        case .waitingForLandmark: return .gray
        case .suspended: return .orange
        case .thresholdPassed, .itemNotInStore: return .red
        }
    }

    private var reasonText: String {
        switch inactiveReason {
        case .none: return ""
        case .externalPause: return "paused"
        case .missingActivationRule: return "no rule for this item"
        case .missingLandmark: return "no landmark passed"
        case .missingProgress: return "no distance reported"
        case .invalidProgress: return "distance is not a number"
        case .invalidActivationRule: return "rule window is invalid"
        case .landmarkMismatch(let supplied, let expected): return "passed \(supplied), rule needs \(expected)"
        case .unreliableProgress: return "position unreliable"
        case .pastDeactivationThreshold(let meters, let end): return String(format: "%.1f m is past the %.1f m end", meters, end)
        case .beforeActivationThreshold(let meters, let start): return String(format: "%.1f m, starts at %.1f m", meters, start)
        case .itemNotInStore: return "item not carried here"
        }
    }
}
