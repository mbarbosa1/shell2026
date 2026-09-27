import AVFoundation
import ItemRecognition
import SwiftUI
import UIKit

struct CameraDemoView: View {
    @StateObject private var model: ScanModel
    @ObservedObject private var calibration: DemoCalibration
    @Environment(\.scenePhase) private var scenePhase

    init(item: DemoItem, calibration: DemoCalibration) {
        _model = StateObject(wrappedValue: ScanModel(item: item, calibration: calibration))
        self.calibration = calibration
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                CameraPreview(session: model.capture.session)
                    .background(Color.black)
                if let position = model.position {
                    PositionBanner(position: position)
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            GateBar(decision: model.gate, meters: calibration.meters)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.awaitingVerdict {
                        InsightVerdict(insight: model.insight, confirm: model.confirmInsight, negate: model.negateInsight)
                    }
                    if let advance = model.advanceNotice {
                        Text(advance)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ScoreCard(model: model)
                    SeenCard(model: model)
                    CalibrationPanel(calibration: calibration, needsRestart: model.needsRestart,
                                     restart: { Task { await model.restart() } })
                }
            }

            HStack {
                Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(model.isRunning ? "Stop" : "Start") {
                    if model.isRunning { model.stop() } else { Task { await model.start() } }
                }
                .buttonStyle(.borderedProminent)
            }
            if model.permissionDenied {
                Button("Open camera settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
        .padding(.horizontal)
        .navigationTitle(model.item.location + " · " + (model.item.visualClass ?? "label"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
        .onDisappear {
            model.stop()
            calibration.setMonkey(false)
        }
        .onChange(of: calibration.live) { _, live in model.apply(live) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.start() } } else { model.stop() }
        }
    }
}

/// Big arrow over the preview: which way to step so the item lands in the middle.
private struct PositionBanner: View {
    let position: PositionAdvice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: position.symbol).font(.system(size: 34, weight: .semibold))
            Text(position.text).font(.title3.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background((position.isCentered ? Color.green : Color.blue).opacity(0.85), in: Capsule())
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct GateBar: View {
    let decision: ActivationDecision?
    let meters: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(decision?.color ?? .gray).frame(width: 12, height: 12)
            Text(decision?.summary ?? "Gate not evaluated yet").font(.subheadline.weight(.medium))
            Spacer()
            Text(String(format: "%.1f m", meters)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// The percentages: how strongly this frame points at the target, and against which threshold.
private struct ScoreCard: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result").font(.headline)
                Spacer()
                Text(model.resultStatus?.rawValue ?? "–")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(statusColor.opacity(0.2), in: Capsule())
            }
            PercentRow(title: model.evidenceSource == .visual ? "Label score" : "Title words read",
                       value: model.scorePercent, threshold: model.thresholdPercent)
            PercentRow(title: "Match confidence", value: model.matchPercent, threshold: nil)
            if !model.item.recognizesByAppearance || model.ocrPercent != nil {
                PercentRow(title: "OCR read quality", value: model.ocrPercent, threshold: nil)
            }
            if let best = model.bestMatch {
                Text(best.id == model.item.id ? "Best match: the target" : "Best match: \(best.title)")
                    .font(.caption)
                    .foregroundStyle(best.id == model.item.id ? Color.primary : Color.orange)
            }
            if let summary = model.readSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var statusColor: Color {
        switch model.resultStatus {
        case .confirmed: return .green
        case .candidate: return .yellow
        case .noMatch: return .orange
        default: return .gray
        }
    }
}

private struct PercentRow: View {
    let title: String
    let value: Int?
    let threshold: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value.map { "\($0)%" } ?? "–").font(.subheadline.monospacedDigit().weight(.semibold))
                if let threshold { Text("needs \(threshold)%").font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(passes ? Color.green : Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(min(value ?? 0, 100)) / 100)
                    if let threshold {
                        Rectangle().fill(Color.primary).frame(width: 2)
                            .offset(x: geometry.size.width * CGFloat(threshold) / 100 - 1)
                    }
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private var passes: Bool { threshold.map { (value ?? 0) >= $0 } ?? false }
}

/// What the recognizer sees right now: produce labels with scores, or the OCR lines with confidence.
private struct SeenCard: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What it sees").font(.headline)
            Text(model.modeMessage).font(.caption).foregroundStyle(.secondary)
            if !model.labels.isEmpty {
                ForEach(model.labels, id: \.identifier) { label in
                    HStack {
                        Text(label.identifier)
                            .fontWeight(label.identifier == model.item.visualClass ? .semibold : .regular)
                        Spacer()
                        Text("\(Int((label.score * 100).rounded()))%").monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
            if !model.lines.isEmpty {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.rawText)
                        Spacer()
                        Text("\(Int((line.confidence * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            if model.labels.isEmpty && model.lines.isEmpty {
                Text("Nothing read yet.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .card()
    }
}

/// The library settled on an answer and waits for the shopper's yes or no.
private struct InsightVerdict: View {
    let insight: String
    let confirm: () -> Void
    let negate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(insight.isEmpty ? "Is this the item you picked?" : "Is this \(insight)?")
                .font(.title3.weight(.semibold))
            HStack {
                Button("Yes, that's it", action: confirm).buttonStyle(.borderedProminent)
                Button("No, keep looking", action: negate).buttonStyle(.bordered)
            }
        }
        .card(Color.accentColor.opacity(0.12))
    }
}

extension View {
    func card(_ background: Color = Color.secondary.opacity(0.12)) -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        // Show the whole frame the recognizer sees, so left/right advice matches the screen.
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
