import AVFoundation
import ItemRecognition
import SwiftUI
import UIKit

struct CameraDemoView: View {
    @StateObject private var model: CameraDemoModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private let onAccepted: (() -> Void)?

    init(configuration: DemoScanConfiguration = .ocrOnly, onAccepted: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: CameraDemoModel(configuration: configuration))
        self.onAccepted = onAccepted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.configuration.title).lineLimit(2)
                Spacer()
                Button("Close") { model.stop(); dismiss() }
            }
            CameraPreview(session: model.capture.session)
                .frame(height: model.configuration.usesDatabase ? 160 : 260)
                .background(Color.black)
            // Which recognizer is working right now. Cloud assist is a heavier
            // model than OCR or Apple Vision, so the user is told when it runs.
            Text(model.modeMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.modeIsCloud ? Color.orange : Color.secondary)
                .accessibilityLabel("Recognition mode: \(model.modeMessage)")
            if let guidance = model.guidanceMessage {
                Text(guidance)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let advance = model.advanceNotice {
                Text(advance)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
            }
            if model.awaitingVerdict {
                InsightVerdict(insight: model.insight, mode: model.modeMessage,
                               confirm: { model.confirmInsight(); onAccepted?() }, negate: { model.negateInsight() })
            }
            if model.showsOCRExtraction {
                OCRExtractionCard(candidates: model.candidates,
                                  ocrConfidencePercent: model.ocrConfidencePercent,
                                  matchConfidencePercent: model.configuration.usesDatabase
                                    ? model.matchConfidencePercent : nil)
            }
            if model.configuration.usesDatabase {
                Text("Manual test progress — not live localization").font(.caption)
                HStack {
                    TextField("Passed landmark", text: $model.landmark).textInputAutocapitalization(.never)
                    TextField("Metres", text: $model.meters).keyboardType(.decimalPad).frame(width: 75)
                }.textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Reliable", isOn: $model.reliable)
                    Toggle("Pause", isOn: $model.paused)
                }
                Button("Apply progress / restart") { Task { model.stop(); await model.start() } }
                Text(model.matchStatus).font(.caption)
            }
            Text(model.configuration.visual == nil
                 ? "Hold the phone upright and point at a label."
                 : "Frame one item clearly. Visual classification does not read a label.")
            Text(model.status).font(.footnote)
            Button(model.isRunning ? "Stop (keep text)" : "Start camera") {
                if model.isRunning { model.stop() }
                else { Task { await model.start() } }
            }
            if model.permissionDenied {
                Button("Open camera permission settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.configuration.visual != nil {
                        Text(model.visualStatus).font(.caption)
                        ForEach(model.visualPredictions, id: \.identifier) { prediction in
                            Text("\(prediction.identifier) = \(Int(prediction.score * 100))%")
                        }
                    }
                    if !model.candidates.isEmpty {
                        Text("All extracted lines").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(model.candidates.enumerated()), id: \.offset) { _, candidate in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.rawText)
                                Text(candidate.normalizedText).font(.caption)
                                Text("OCR confidence: \(Int((candidate.confidence * 100).rounded()))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if model.showsOCRExtraction {
                        Text("No extracted text.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding()
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.start() } }
            else { model.stop() }
        }
    }
}

@MainActor
final class CameraDemoModel: ObservableObject {
    let configuration: DemoScanConfiguration
    @Published var landmark: String
    @Published var meters: String
    @Published var reliable = true
    @Published var paused = false
    @Published private(set) var matchStatus = ""
    @Published private(set) var status = "Camera not started."
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var candidates: [RecognizedTextCandidate] = []
    /// Mean of the latest OCR line confidences, 0…100. Nil until OCR has produced a frame.
    @Published private(set) var ocrConfidencePercent: Int?
    /// Latest `ItemRecognitionResult.matchConfidence`, 0…100, when a result exists.
    @Published private(set) var matchConfidencePercent: Int?
    @Published private(set) var visualPredictions: [VisualClassification] = []
    @Published private(set) var visualStatus = "Waiting for visual evidence."
    /// OCR path, or leftover OCR lines if a visual session somehow has them.
    var showsOCRExtraction: Bool { configuration.visual == nil || !candidates.isEmpty }
    /// Plain-language direction from the latest processed frame, or nil when
    /// the item is framed well enough. Never coordinates.
    @Published private(set) var guidanceMessage: String?
    /// Which recognizer produced the latest update: OCR, Apple Vision, or Gemini.
    @Published private(set) var modeMessage: String
    @Published private(set) var modeIsCloud = false
    @Published private(set) var awaitingVerdict = false
    @Published private(set) var insight = ""
    @Published private(set) var advanceNotice: String?
    private var lastConsoleMessage: String?
    private var lastGuidanceLogged: RecognitionGuidance?
    private var lastModeLogged: RecognitionModeNotice?
    private var lastOCRLogged: String?
    private var visualClassifier: (any VisualClassifying)?

    init(configuration: DemoScanConfiguration) {
        self.configuration = configuration
        landmark = configuration.rule?.landmarkID ?? ""
        meters = configuration.rule.map { String($0.activateAfterMeters) }
            ?? (configuration.usesDatabase ? "0" : "5")
        modeMessage = (configuration.visual == nil ? RecognitionModeNotice.ocrOnly : .appleVision).message
    }

    lazy var capture = DemoCameraCapture { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event) }
    }

    func start() async {
        guard !isRunning else { return }
        guard let progress = Double(meters), progress.isFinite else { status = "Enter a finite progress value."; return }
        isRunning = true
        status = "Requesting camera access…"
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard isRunning else { return } // App may have left the foreground during the prompt.
        permissionDenied = !allowed
        guard allowed else {
            isRunning = false
            status = "Camera access is off. Enable it in Settings, then tap Start camera."
            return
        }
        candidates = []
        ocrConfidencePercent = nil
        matchConfidencePercent = nil
        visualPredictions = []
        visualStatus = "Waiting for visual evidence."
        matchStatus = ""
        guidanceMessage = nil
        modeIsCloud = false
        modeMessage = (configuration.visual == nil ? RecognitionModeNotice.ocrOnly : .appleVision).message
        lastConsoleMessage = nil
        lastGuidanceLogged = nil
        lastModeLogged = nil
        lastOCRLogged = nil
        status = "Starting rear camera…"
        do {
            if let visual = configuration.visual, visualClassifier == nil {
                visualClassifier = try DemoCloudAssist.visualClassifier(for: visual)
            }
            let visualPolicy = configuration.visual.map(DemoCloudAssist.visualPolicy(for:)) ?? VisualRecognitionPolicy()
            let fallback: (any VisualClassifying)? = configuration.visual == nil
                ? try ProduceCategoryClassifier(base: VisionImageClassifier(), cloud: DemoCloudAssist.labeler(),
                    cloudPolicy: CloudAssistPolicy(localScoreBelow: VisualRecognitionPolicy.appleVisionProduce.minimumScore))
                : nil
            let coordinator = try await RecognitionCoordinator(targetID: configuration.targetID,
                catalog: configuration.catalog, visualClassifier: visualClassifier, visualPolicy: visualPolicy,
                ocrFallback: fallback)
            guard isRunning else { await coordinator.stop(); return }
            let context = RecognitionContext(targetItemID: configuration.targetID,
                landmarkProgress: LandmarkProgressObservation(timestamp: 0,
                    passedLandmarkID: landmark.isEmpty ? nil : landmark, metersPastLandmark: progress, isReliable: reliable),
                externalPause: paused)
            capture.start(coordinator: coordinator, context: context)
        } catch { isRunning = false; status = error.localizedDescription }
    }

    func confirmInsight() {
        let accepted = insight
        capture.acceptInsight()
        awaitingVerdict = false
        stop()
        status = "You confirmed \(accepted)."
    }

    func negateInsight() {
        capture.rejectInsight()
        awaitingVerdict = false
        insight = ""
        status = "Not that. Looking again."
    }

    func stop() {
        isRunning = false
        capture.stop()
        status = "Stopped. Last extracted text is kept below."
    }

    /// The selected item's labels always (even at 0%), other produce labels above 0%,
    /// and the background as `unknown(<raw Vision label>)`.
    private func displayPredictions(_ evidence: VisualObservation?) -> [VisualClassification] {
        guard let evidence else { return [] }
        let targets = configuration.visual?.classIDs ?? []
        var lines = targets.sorted().map { target in
            evidence.classifications.first { $0.identifier == target } ?? VisualClassification(identifier: target, score: 0)
        }
        lines += evidence.classifications
            .filter { !targets.contains($0.identifier) && $0.identifier != "unknown" && $0.score > 0 }
            .prefix(3)
        if let unknown = evidence.classifications.first(where: { $0.identifier == "unknown" }), unknown.score > 0 {
            let name = evidence.backgroundLabel.map { "unknown(\($0))" } ?? "unknown"
            lines.append(VisualClassification(identifier: name, score: unknown.score))
        }
        return lines.sorted { $0.score > $1.score }
    }

    /// Keep the last OCR lines across skipped frames so the text does not flicker
    /// four times out of five. A processed observation, even with no lines, replaces it.
    private func applyExtraction(_ update: RecognitionUpdate) {
        if let observation = update.observation {
            candidates = observation.candidates
            if observation.candidates.isEmpty {
                ocrConfidencePercent = nil
            } else {
                let mean = observation.candidates.map(\.confidence).reduce(0, +)
                    / Float(observation.candidates.count)
                ocrConfidencePercent = Int((mean * 100).rounded())
            }
            let text = observation.candidates.map(\.rawText).joined(separator: " | ")
            let confidence = ocrConfidencePercent.map { "\($0)%" } ?? "none"
            let signature = "\(text)|\(confidence)"
            if signature != lastOCRLogged {
                print("[ItemRecognition] OCR: \(text.isEmpty ? "No text extracted" : text) | confidence \(confidence)")
                lastOCRLogged = signature
            }
        }
        if let result = update.result {
            matchConfidencePercent = Int((result.matchConfidence * 100).rounded())
        }
    }

    /// Mode is shown on every update. Guidance follows the latest processed frame:
    /// a frame with no advice clears the banner. Both are logged when they change.
    private func applyNotices(_ update: RecognitionUpdate) {
        modeMessage = update.modeNotice.message
        modeIsCloud = update.modeNotice == .cloudAssist
        if update.modeNotice != lastModeLogged {
            print("[ItemRecognition] Mode: \(update.modeNotice.message)")
            lastModeLogged = update.modeNotice
        }
        // Skipped or discarded frames carry no result; keep the last advice until a processed frame replaces it.
        guard update.result != nil, update.gate.isDetectionActive else { return }
        guidanceMessage = update.guidance?.message
        if update.guidance != lastGuidanceLogged {
            if let guidance = update.guidance { print("[ItemRecognition] Guidance: \(guidance.message)") }
            lastGuidanceLogged = update.guidance
        }
    }

    private func receive(_ event: DemoCameraCapture.Event) {
        guard isRunning else { return }
        switch event {
        case .started:
            status = configuration.visual == nil ? "Scanning. Point at clear, well-lit text." : "Scanning item appearance."
        case .update(let update, let milliseconds):
            applyExtraction(update)
            applyNotices(update)
            if update.gate.isDetectionActive {
                status = configuration.visual == nil
                    ? "\(candidates.count) lines · \(Int(milliseconds)) ms processing"
                    : "Visual classification · \(Int(milliseconds)) ms processing"
            } else {
                status = "Gate: \(update.gate.state) · \(String(describing: update.gate.inactiveReason))"
            }
            awaitingVerdict = update.awaitingVerdict
            if update.awaitingVerdict { insight = update.insight ?? "" }
            advanceNotice = update.advanceNotice ?? advanceNotice
            if let result = update.result {
                let matchPercent = Int((result.matchConfidence * 100).rounded())
                matchStatus = "\(result.evidenceSource.rawValue) · \(result.status.rawValue) · match \(matchPercent)% · evidence score \(Int(result.score * 100))%"
                visualPredictions = displayPredictions(result.visualEvidence)
                let mappedClass = result.visualEvidence?.classifications
                    .filter { configuration.visual?.classIDs.contains($0.identifier) == true }
                    .max { $0.score < $1.score }?.identifier ?? "item"
                switch result.visualMatchReason {
                case .categoryOnly:
                    visualStatus = "\(mappedClass) category recognized. Exact catalog product remains unverified."
                case .ambiguousCatalog:
                    visualStatus = "Multiple catalog items share this visual class."
                case .accepted:
                    visualStatus = result.status == .confirmed ? "Catalog item confirmed." : "Collecting repeated visual evidence."
                case .acceptedCategory:
                    visualStatus = result.status == .confirmed
                        ? "\(mappedClass) confirmed (category level; variety not checked)."
                        : "\(mappedClass) seen. Collecting repeated visual evidence."
                case .insufficientEvidence:
                    visualStatus = "Insufficient visual evidence for the selected product."
                case nil:
                    visualStatus = "Waiting for visual evidence."
                }
                if let evidence = result.visualEvidence {
                    visualStatus = "[\(evidence.kind == .cloudSuggestion ? "cloud" : "on-device")] \(visualStatus)"
                    if let diagnostic = evidence.diagnostic, evidence.kind != .cloudSuggestion {
                        visualStatus += " \(diagnostic)"
                    }
                }
                let text = candidates.map(\.rawText).joined(separator: " | ")
                let item: String
                if configuration.usesDatabase, result.status == .confirmed,
                   let matchedID = result.matchedItemID, matchedID == configuration.targetID {
                    item = "\(configuration.title) | TCIN: \(configuration.catalogKey ?? "unknown") | ID: \(matchedID)"
                } else {
                    item = "No confirmed database match"
                }
                let evidence = result.evidenceSource == .visual
                    ? "Visual: \(visualPredictions.map { "\($0.identifier)=\(Int($0.score * 100))%" }.joined(separator: ", ")) | \(visualStatus)"
                    : "OCR: \(text.isEmpty ? "No text extracted" : text)"
                let message = "[ItemRecognition] \(result.status.rawValue) | Match: \(matchPercent)% | Item: \(item) | \(evidence)"
                // Ignore score jitter when deciding whether to repeat a diagnostic;
                // reprint when the match confidence moves by a 10-point step.
                let signature = result.evidenceSource == .visual
                    ? "\(result.status.rawValue)|\(matchPercent / 10)|\(item)|\(visualPredictions.map(\.identifier))|\(visualStatus)"
                    : message
                if signature != lastConsoleMessage {
                    print(message)
                    lastConsoleMessage = signature
                }
            }
        case .failure(let message):
            isRunning = false
            status = message
            matchStatus = "Recognition unavailable"
            visualPredictions = []
            print("[ItemRecognition] Error: \(message)")
        }
    }
}

/// Latest OCR output and the confidence Vision assigned when it produced it.
/// Match confidence is the catalog fit, shown only when the session is matching.
/// The settled OCR words or the object Apple Vision / Gemini named.
/// Scanning stays on this result until the user confirms or rejects it.
private struct InsightVerdict: View {
    let insight: String
    let mode: String
    let confirm: () -> Void
    let negate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode).font(.caption).foregroundStyle(.secondary)
            Text(insight.isEmpty ? "Is this the product you selected?" : "Is this \(insight)?")
                .font(.title3.weight(.semibold))
            HStack {
                Button("Accept", action: confirm)
                    .buttonStyle(.borderedProminent)
                Button("Deny", action: negate)
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
    }
}

private struct OCRExtractionCard: View {
    let candidates: [RecognizedTextCandidate]
    let ocrConfidencePercent: Int?
    let matchConfidencePercent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extracted text")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let ocrConfidencePercent {
                    Text("OCR \(ocrConfidencePercent)%")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel("OCR confidence \(ocrConfidencePercent) percent")
                }
                if let matchConfidencePercent {
                    Text("Match \(matchConfidencePercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Match confidence \(matchConfidencePercent) percent")
                }
            }
            if candidates.isEmpty {
                Text("No extracted text.")
                    .foregroundStyle(.secondary)
            } else {
                Text(candidates.map(\.rawText).joined(separator: "\n"))
                    .textSelection(.enabled)
                    .accessibilityLabel("Extracted text: \(candidates.map(\.rawText).joined(separator: ", "))")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.setNeedsLayout()
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}
