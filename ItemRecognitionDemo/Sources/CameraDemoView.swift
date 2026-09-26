import AVFoundation
import ItemRecognition
import SwiftUI
import UIKit

struct CameraDemoView: View {
    @StateObject private var model: CameraDemoModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(configuration: DemoScanConfiguration = .ocrOnly) {
        _model = StateObject(wrappedValue: CameraDemoModel(configuration: configuration))
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
                    } else if model.candidates.isEmpty {
                        Text("No extracted text.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.candidates.enumerated()), id: \.offset) { _, candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.rawText)
                            Text(candidate.normalizedText).font(.caption)
                            Text("OCR confidence: \(Int(candidate.confidence * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
    @Published private(set) var visualPredictions: [VisualClassification] = []
    @Published private(set) var visualStatus = "Waiting for visual evidence."
    private var lastConsoleMessage: String?
    private var visualClassifier: (any VisualClassifying)?

    init(configuration: DemoScanConfiguration) {
        self.configuration = configuration
        landmark = configuration.rule?.landmarkID ?? ""
        meters = configuration.usesDatabase ? "0" : "5"
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
        visualPredictions = []
        visualStatus = "Waiting for visual evidence."
        matchStatus = ""
        lastConsoleMessage = nil
        status = "Starting rear camera…"
        do {
            if let visual = configuration.visual, visualClassifier == nil {
                visualClassifier = try DemoCloudAssist.visualClassifier(for: visual)
            }
            let visualPolicy = configuration.visual.map(DemoCloudAssist.visualPolicy(for:)) ?? VisualRecognitionPolicy()
            let coordinator = try await RecognitionCoordinator(targetID: configuration.targetID,
                catalog: configuration.catalog, visualClassifier: visualClassifier, visualPolicy: visualPolicy)
            guard isRunning else { await coordinator.stop(); return }
            let context = RecognitionContext(targetItemID: configuration.targetID,
                landmarkProgress: LandmarkProgressObservation(timestamp: 0,
                    passedLandmarkID: landmark.isEmpty ? nil : landmark, metersPastLandmark: progress, isReliable: reliable),
                externalPause: paused)
            capture.start(coordinator: coordinator, context: context)
        } catch { isRunning = false; status = error.localizedDescription }
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

    private func receive(_ event: DemoCameraCapture.Event) {
        guard isRunning else { return }
        switch event {
        case .started:
            status = configuration.visual == nil ? "Scanning. Point at clear, well-lit text." : "Scanning item appearance."
        case .update(let update, let milliseconds):
            candidates = update.observation?.candidates ?? []
            if update.gate.isDetectionActive {
                status = configuration.visual == nil
                    ? "\(candidates.count) lines · \(Int(milliseconds)) ms processing"
                    : "Visual classification · \(Int(milliseconds)) ms processing"
            } else {
                status = "Gate: \(update.gate.state) · \(String(describing: update.gate.inactiveReason))"
            }
            if let result = update.result {
                matchStatus = "\(result.evidenceSource.rawValue) · \(result.status.rawValue) · evidence score \(Int(result.score * 100))%"
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
                let message = "[ItemRecognition] \(result.status.rawValue) | Item: \(item) | \(evidence)"
                // Ignore score jitter when deciding whether to repeat a diagnostic.
                let signature = result.evidenceSource == .visual
                    ? "\(result.status.rawValue)|\(item)|\(visualPredictions.map(\.identifier))|\(visualStatus)"
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
