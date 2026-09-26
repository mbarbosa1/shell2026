import AVFoundation
import ItemRecognition
import SwiftUI
import UIKit

struct CameraDemoView: View {
    @StateObject private var model = CameraDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CameraPreview(session: model.capture.session)
                .frame(height: 260)
                .background(Color.black)
            Text("Hold the phone upright and point at a label.")
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
                    if model.candidates.isEmpty {
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.start() } }
            else { model.stop() }
        }
    }
}

@MainActor
final class CameraDemoModel: ObservableObject {
    @Published private(set) var status = "Camera not started."
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var candidates: [RecognizedTextCandidate] = []

    lazy var capture = DemoCameraCapture { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event) }
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
        guard isRunning else { return } // App may have left the foreground during the prompt.
        permissionDenied = !allowed
        guard allowed else {
            isRunning = false
            status = "Camera access is off. Enable it in Settings, then tap Start camera."
            return
        }
        candidates = []
        status = "Starting rear camera…"
        capture.start()
    }

    func stop() {
        isRunning = false
        capture.stop()
        status = "Stopped. Last extracted text is kept below."
    }

    private func receive(_ event: DemoCameraCapture.Event) {
        guard isRunning else { return }
        switch event {
        case .started:
            status = "Scanning. Point at clear, well-lit text."
        case .result(let observation, let milliseconds):
            candidates = observation.candidates
            status = "\(candidates.count) lines · \(Int(milliseconds)) ms detection + OCR"
        case .noText:
            candidates = []
            status = "No label text detected. Move closer or improve the lighting."
        case .failure(let message):
            isRunning = false
            status = message
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
