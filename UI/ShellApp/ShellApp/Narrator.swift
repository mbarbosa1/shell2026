import AVFoundation

/// Reads text aloud when the voice agent can't, e.g. before the user has allowed the microphone.
/// If the app has a recording named `clip` (e.g. `onboarding_welcome.mp3`, made with the agent's
/// ElevenLabs voice), it plays that so the voice matches the agent. Otherwise it uses Apple's voice.
@MainActor
final class Narrator: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    /// The line playing now (its utterance or player). A "finished" for any other line is from one
    /// that was cut off, and is ignored.
    private var currentLine: ObjectIdentifier?
    /// True from `speak` until the last line finishes. A line cut off by a new one doesn't end it.
    private var isSpeaking = false
    /// Waiting for `isSpeaking` to go false (see `whenQuiet`).
    private var quietActions: [() -> Void] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, clip: String? = nil, onFinish: (() -> Void)? = nil) {
        interrupt()
        isSpeaking = true
        self.onFinish = onFinish

        let session = AVAudioSession.sharedInstance()
        // Leave the audio setup alone while the voice agent is using the mic, or it cuts the agent off.
        if session.category != .playAndRecord {
            // .playback still plays when the silent switch is on.
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }

        if let clip,
           let url = Bundle.main.url(forResource: clip, withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.play()
            self.player = player
            currentLine = ObjectIdentifier(player)
        } else {
            let utterance = AVSpeechUtterance(string: text)
            currentLine = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
        }
    }

    /// Stops talking and drops anything waiting in `whenQuiet`.
    func stop() {
        interrupt()
        isSpeaking = false
        quietActions = []
    }

    /// Runs `action` once nothing is being said, right away if that's now. Lines that cut each
    /// other off count as one, so it waits for the last. `stop()` cancels it.
    func whenQuiet(_ action: @escaping () -> Void) {
        guard isSpeaking else { return action() }
        quietActions.append(action)
    }

    /// Cuts off the current line without running its `onFinish`.
    private func interrupt() {
        onFinish = nil
        currentLine = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finished(_ line: ObjectIdentifier) {
        // A late "finished" from a line that was cut off: the new one is still going. (Checking
        // `synthesizer.isSpeaking` doesn't work: it's still true when a line reports finishing.)
        guard line == currentLine else { return }
        currentLine = nil
        player = nil
        isSpeaking = false
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?()
        // `onFinish` may have started the next line.
        guard !isSpeaking else { return }
        let actions = quietActions
        quietActions = []
        actions.forEach { $0() }
    }
}

extension Narrator: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let line = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(line) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let line = ObjectIdentifier(player)
        Task { @MainActor in self.finished(line) }
    }
}