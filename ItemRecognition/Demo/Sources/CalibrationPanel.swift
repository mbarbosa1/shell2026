import SwiftUI

/// Hand and monkey controls for `DemoCalibration`. Used on the scan screen and from the item list.
struct CalibrationPanel: View {
    @ObservedObject var calibration: DemoCalibration
    var needsRestart = false
    var restart: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tester calibration — navigation stand-in, not shopper UI")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            live
            monkey
            session
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position – applies on the next frame").font(.headline)
            LabeledSlider(title: "Metres past landmark", value: $calibration.meters,
                          range: calibration.meterRange, step: 0.1, format: "%.1f m")
            Toggle("Position reliable", isOn: $calibration.reliable)
            Toggle("Paused by navigation", isOn: $calibration.paused)
            Toggle("Report the wrong landmark", isOn: $calibration.reportsWrongLandmark)
            Button("Reset position") { calibration.resetLive() }
        }
        .disabled(calibration.monkeyEnabled)
        .card()
    }

    private var monkey: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { calibration.monkeyEnabled }, set: { calibration.setMonkey($0) })) {
                VStack(alignment: .leading) {
                    Text("Monkey test").font(.headline)
                    Text("Every second: random walk or jump in metres, and a 10% chance each of pause, unreliable, wrong landmark.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if calibration.monkeyEnabled || !calibration.monkeyLog.isEmpty {
                ForEach(Array(calibration.monkeyLog.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .card()
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window and thresholds – restart the scan").font(.headline)
            HStack {
                Text("Landmark")
                TextField("Landmark ID", text: $calibration.session.landmarkID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledSlider(title: "Start recognizing at", value: $calibration.session.activateAfterMeters,
                          range: 0...30, step: 0.5, format: "%.1f m")
            LabeledSlider(title: "Stop recognizing after", value: $calibration.session.deactivateAfterMeters,
                          range: 0...40, step: 0.5, format: "%.1f m")
            LabeledSlider(title: "List words read (OCR)", value: $calibration.session.matchCoverage,
                          range: 0.1...1, step: 0.05, format: "%.0f%%", scale: 100)
            LabeledSlider(title: "Produce score (Apple Vision)", value: $calibration.session.produceScore,
                          range: 0.05...1, step: 0.05, format: "%.0f%%", scale: 100)
            HStack {
                Button("Defaults") { calibration.session = DemoCalibration.defaultSession }
                Spacer()
                if needsRestart, let restart {
                    Button("Restart to apply", action: restart).buttonStyle(.borderedProminent)
                }
            }
        }
        .card(needsRestart ? Color.yellow.opacity(0.15) : Color.secondary.opacity(0.12))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $value, in: range, step: step)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(format: format, value * scale))
    }
}
