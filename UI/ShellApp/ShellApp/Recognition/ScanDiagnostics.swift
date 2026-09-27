import Foundation
import ItemRecognition

/// A tester's snapshot of the real pipeline, never a second recognition decision.
struct ScanDiagnostics {
    struct Event: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    var isRunning = false
    var status = "Preparing camera"
    var latest: RecognitionUpdate?
    var cloud: CloudAssistUsage?
    var cloudConfigured = false
    var cloudEndpoint: String?
    var receivedFrames = 0
    var busyFrames = 0
    var processedFrames = 0
    var milliseconds: Int?
    var lastFrameAt: Date?
    var lastEvidenceAt: Date?
    var error: String?
    var receipt: ItemObservation?
    var deadlineReached = false
    var events: [Event] = []
    var tally = RecognitionStageTally()
    private var lastEvent: String?

    mutating func note(_ message: String) {
        guard message != lastEvent else { return }
        lastEvent = message
        events.insert(Event(message: message), at: 0)
        if events.count > 12 { events.removeLast(events.count - 12) }
    }

    mutating func record(_ update: RecognitionUpdate, milliseconds: Int) {
        // Cadence-skipped updates contain no evidence. Preserve the last actual
        // frame, with its age, instead of flashing zero scores between inferences.
        guard update.result != nil || update.advanceNotice != nil else { return }
        let repeated = latest?.awaitingVerdict == true && update.awaitingVerdict
        deadlineReached = update.advanceNotice != nil
        if update.result != nil { latest = update }
        error = nil
        if !repeated {
            self.milliseconds = milliseconds
            if update.assessment != nil || update.didRunOCR || update.visualObservation != nil {
                lastEvidenceAt = Date()
                processedFrames += 1
            }
            if let stage = update.stageOutcome {
                tally.record(stage)
                note("\(stage.stage.name) · \(stage.reason)")
            }
        }
        if update.awaitingVerdict { status = "Waiting for your answer" }
        else if update.advanceNotice != nil { status = "Timed out · start a new trial" }
        else if !update.gate.isDetectionActive { status = "Recognition paused" }
        else { status = "Scanning" }
    }

    var explanation: String {
        if let error { return error }
        if receipt != nil { return "You validated this scan. The test leaves your shopping list unchanged." }
        guard let update = latest else { return "Waiting for the first camera assessment." }
        if update.awaitingVerdict { return "The evidence passed. Your Yes or No is the final check." }
        if deadlineReached { return "The one-minute scan window ended. Last evidence is retained below. Start a new trial to scan again." }
        if !update.gate.isDetectionActive {
            return "Recognition is paused: \(update.gate.inactiveReason?.code ?? String(describing: update.gate.state))."
        }
        guard let stage = update.stageOutcome else { return "Waiting for the next processed frame." }
        switch stage.stage {
        case .activation: return "Waiting for the item's location and reliable tracking."
        case .localization:
            if stage.reason == "notLocated" {
                return "No foreground object located. Bring the item into view. Configured Gemini can try the full frame after its countdown."
            }
            return update.assessment?.message ?? "Hold the camera steady so the item can be located."
        case .cropping: return update.assessment?.message ?? "The label is not readable yet. Turn it toward the camera."
        case .ocrOrClassification:
            if update.visualObservation != nil {
                return stage.reason == "targetClassAbsent"
                    ? "The recognizer did not return the target's label. Check the labels below and adjust the view."
                    : "The target score or its lead over another produce label is too low."
            }
            return "No readable label words came back. Turn the label toward the camera."
        case .matching: return "The evidence does not distinguish this item yet. Check the best match and words below."
        case .confirming: return "This frame passed. Hold still while the remaining observations are collected."
        case .awaitingShopper: return "The evidence passed. Your Yes or No is the final check."
        }
    }
}
