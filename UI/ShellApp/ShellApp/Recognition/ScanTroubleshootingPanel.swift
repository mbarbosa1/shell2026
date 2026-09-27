#if DEBUG
import ItemRecognition
import SwiftUI

/// Live evidence from the scanner, styled as an expandable instrument panel.
/// Scores always refer to the last assessed frame; freshness is shown separately.
struct ScanTroubleshootingPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showEvidence = true
    @State private var showHistory = false

    private var scanner: ItemScanner { model.scanner }
    private var data: ScanDiagnostics { scanner.diagnostics }
    private var appearance: Bool { scanner.target?.catalog.recognizesByAppearance == true }
    private var policy: VisualRecognitionPolicy { .appleVisionProduce }
    private var targetClasses: Set<String> {
        guard let catalog = scanner.target?.catalog else { return [] }
        return catalog.candidates.first { $0.id == catalog.targetID }?.visual?.classIDs ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    guidance
                    if let prompt = scanner.question {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(prompt).font(.headline)
                            if data.latest?.result?.matchLevel == .category {
                                Text("Category recognized. Check variety and size before accepting.")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            HStack {
                                Button("No, keep looking") { scanner.answer(false) }
                                    .buttonStyle(.bordered)
                                Button("Yes, validate scan") { scanner.answer(true) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    scores
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("WHY THIS FRAME", symbol: "line.3.horizontal.decrease.circle")
                        Text(data.explanation).font(.subheadline)
                        if let update = data.latest {
                            diagnosticRow("Stopped at", update.stageOutcome.map { "\($0.stage.name) · \($0.reason)" } ?? "No new evidence")
                            diagnosticRow("Activation", update.gate.isDetectionActive ? "Active" : update.gate.inactiveReason?.code ?? "Paused")
                            diagnosticRow("Camera", update.assessment?.quality.rawValue ?? "Not assessed")
                            diagnosticRow("Object regions", String(update.assessment?.objectBoxes.count ?? 0))
                            if let boxes = update.assessment?.objectBoxes, !boxes.isEmpty {
                                let area = boxes.map { $0.width * $0.height }.max() ?? 0
                                diagnosticRow("Largest object / frame", "\(Int(area * 100))%")
                            }
                            if let result = update.result {
                                diagnosticRow("Frame passes policy", result.passesPolicy ? "Yes" : "No")
                                diagnosticRow("Confirmation", "\(update.confirmationCount) / \(update.requiredConfirmations) observations")
                                if appearance, let evidence = result.visualEvidence {
                                    let competitor = evidence.classifications.filter {
                                        !targetClasses.contains($0.identifier) && $0.identifier != "unknown"
                                    }.map(\.score).max() ?? 0
                                    diagnosticRow("Lead over next produce", "\(Int((result.score - competitor) * 100)) points / \(Int(policy.minimumMargin * 100)) needed")
                                }
                            }
                        }
                    }
                    if appearance { cloudStatus }
                    DisclosureGroup("What the camera sees", isExpanded: $showEvidence) { evidence.padding(.top, 8) }
                        .font(.subheadline.weight(.semibold))
                    performance
                    DisclosureGroup("Recent events", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(data.events) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(event.time, style: .time).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                    Text(event.message)
                                }.font(.caption)
                            }
                        }.padding(.top, 8)
                    }.font(.subheadline.weight(.semibold))
                }
                .padding(16)
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Test only · shopping list unchanged")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                if data.isRunning {
                    Button("Stop") { scanner.stopTrial() }.buttonStyle(.bordered)
                } else {
                    Button("New trial") { scanner.restartTarget() }.buttonStyle(.borderedProminent)
                }
            }.padding(12)
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accentText)
        .background(Theme.background.opacity(0.97), in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.accentText.opacity(0.35)) }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form { CloudAssistSettingsSection() }
                    .navigationTitle("Recognition settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply & restart") {
                                showSettings = false
                                scanner.restartTarget()
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .task {
            while !Task.isCancelled {
                await scanner.refreshCloudUsage()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: data.receipt == nil ? "viewfinder" : "checkmark.seal.fill")
                .font(.title2).foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text("RECOGNITION LAB").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(Theme.accentText)
                Text(data.status).font(.headline)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Recognition and Gemini settings")
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var guidance: some View {
        Label {
            Text(viewInstruction)
                .font(.headline)
        } icon: {
            Image(systemName: guidanceSymbol).font(.title2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.accentText.opacity(0.10), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var viewInstruction: String {
        if data.receipt != nil { return "Scan validated" }
        if scanner.question != nil { return "Check the item, then answer below" }
        if data.deadlineReached { return "Scan window ended. Start a new trial." }
        if !data.isRunning { return data.status }
        if data.latest?.gate.isDetectionActive == false { return "Recognition paused. Check the activation reason below." }
        return scanner.hint ?? "Bring the item into the camera view"
    }

    private var guidanceSymbol: String {
        if data.receipt != nil { return "checkmark.circle.fill" }
        switch data.latest?.guidance {
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveCloser, .keepWalking: return "arrow.up"
        case .moveBack: return "arrow.down"
        case .holdSteady: return "hand.raised"
        case .showLabel: return "arrow.triangle.2.circlepath"
        case nil: return "scope"
        }
    }

    private var scores: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("LAST FRAME", symbol: "waveform.path")
                Spacer()
                Text(data.latest?.modeNotice.message ?? (appearance ? "Apple Vision" : "OCR"))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            let result = data.latest?.result
            // A localization failure is not a classifier score of zero.
            let hasEvidence = result?.visualEvidence != nil || data.latest?.didRunOCR == true
            scoreBar(appearance ? "Target model score" : "List words matched",
                     value: hasEvidence ? result?.score : nil,
                     threshold: appearance ? policy.minimumScore : RecognitionPolicy().minimumQueryScore)
            scoreBar("Match confidence", value: hasEvidence ? result?.matchConfidence : nil, threshold: nil)
            Text("Model scores and smoothed confidence are evidence, not calibrated probabilities.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private func scoreBar(_ title: String, value: Float?, threshold: Float?) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value.map { "\(Int($0 * 100))%" } ?? "—").font(.headline.monospacedDigit())
                if let threshold { Text("/ \(Int(threshold * 100))% needed").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.accentText).frame(width: geometry.size.width * CGFloat(min(max(value ?? 0, 0), 1)))
                    if let threshold {
                        Rectangle().fill(Theme.textPrimary).frame(width: 2, height: 10)
                            .offset(x: geometry.size.width * CGFloat(threshold))
                    }
                }
            }.frame(height: 6)
        }.accessibilityElement(children: .combine)
    }

    private var cloudStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("GEMINI FALLBACK", symbol: "cloud")
                Spacer()
                if data.isRunning, data.cloud?.isRequestInFlight == true { ProgressView() }
            }
            if !data.cloudConfigured {
                Label("Not configured · fallback cannot run", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
                Button("Configure proxy") { showSettings = true }.font(.subheadline.weight(.semibold))
            } else {
                diagnosticRow("Proxy", data.cloudEndpoint ?? "Configured")
                diagnosticRow("Attempts", "\(data.cloud?.calls ?? 0) / \(data.cloud?.limit ?? 2)")
                Text(cloudMessage).font(.subheadline)
                if let label = data.cloud?.lastLabel {
                    diagnosticRow("Last answer", "\(label.label) · \(Int(label.confidence * 100))% · \(label.model)")
                }
                if let seconds = data.cloud?.lastSeconds { diagnosticRow("Last request", String(format: "%.2f s", seconds)) }
                if let failure = data.cloud?.lastFailure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Theme.cardRaised, in: .rect(cornerRadius: 14))
    }

    private var cloudMessage: String {
        if !data.isRunning { return "Trial ended. Start a new trial for more attempts." }
        if data.cloud?.isRequestInFlight == true { return "Asking Gemini… hold the camera steady." }
        if scanner.question != nil { return "A match is ready. No further cloud request is needed." }
        if data.deadlineReached { return "Scan timed out. Start a new trial." }
        if data.latest?.gate.isDetectionActive == false { return "Waiting for activation. Recognition is paused." }
        if let usage = data.cloud, usage.calls >= usage.limit { return "Attempts used. Apple Vision continues until the scan deadline." }
        if let seconds = data.cloud?.secondsUntilCall {
            if seconds <= 0 { return "Ready for Gemini. Waiting for a steady, focused frame." }
            return "Apple Vision first · Gemini eligible in \(Int(ceil(seconds))) s"
        }
        return "Waiting for the first active camera frame."
    }

    @ViewBuilder private var evidence: some View {
        if appearance {
            if let observation = data.latest?.visualObservation {
                let labels = observation.classifications.filter { $0.score > 0 || targetClasses.contains($0.identifier) }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targetClasses.sorted(), id: \.self) { label in
                        diagnosticRow("Target · \(label)", "\(Int((labels.first { $0.identifier == label }?.score ?? 0) * 100))%")
                    }
                    ForEach(Array(labels.filter { !targetClasses.contains($0.identifier) }.prefix(6)), id: \.identifier) { label in
                        diagnosticRow(label.identifier == "unknown" ? "Background · \(observation.backgroundLabel ?? "unknown")" : label.identifier,
                                      "\(Int(label.score * 100))%")
                    }
                    if let diagnostic = observation.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(Theme.textSecondary) }
                }
            } else { Text("No classification for this frame. See the blocking reason above.").font(.caption) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let id = data.latest?.result?.leadingItemID,
                   let candidate = scanner.target?.catalog.candidates.first(where: { $0.id == id }) {
                    diagnosticRow("Best match", candidate.displayName)
                }
                ForEach(Array((data.latest?.observation?.candidates ?? []).enumerated()), id: \.offset) { _, line in
                    diagnosticRow(line.rawText, "\(Int(line.confidence * 100))% OCR")
                }
                if data.latest?.observation?.candidates.isEmpty != false { Text("No words read yet.").font(.caption) }
            }
        }
    }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("FRAME HEALTH", symbol: "speedometer")
            diagnosticRow("Received / assessed", "\(data.receivedFrames) / \(data.processedFrames)")
            diagnosticRow("Dropped while busy", String(data.busyFrames))
            diagnosticRow("Last processing time", data.milliseconds.map { "\($0) ms" } ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                diagnosticRow("Last camera frame", age(data.lastFrameAt, now: context.date))
                diagnosticRow("Last evidence", age(data.lastEvidenceAt, now: context.date))
            }
            ForEach(data.tally.topReasons(3), id: \.reason) { reason in
                diagnosticRow(reason.reason, "\(reason.count) frames")
            }
        }
    }

    private func age(_ date: Date?, now: Date) -> String {
        date.map { "\(max(0, Int(now.timeIntervalSince($0)))) s ago" } ?? "None received"
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(Theme.accentText)
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(.caption).accessibilityElement(children: .combine)
    }
}
#endif
