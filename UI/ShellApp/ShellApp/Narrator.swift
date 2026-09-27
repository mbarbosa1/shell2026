import AVFoundation

/// Reads text aloud when the voice agent can't, e.g. before the user has allowed the microphone.
/// If the app has a recording named `clip` (e.g. `onboarding_welcome.mp3`, made with the agent's
/// ElevenLabs voice), it plays that so the voice matches the agent. Otherwise it uses Apple's voice.
@MainActor
final class Narrator: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, clip: String? = nil, onFinish: (() -> Void)? = nil) {
        stop()
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
        } else {
            synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }

    func stop() {
        onFinish = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finished() {
        player = nil
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?()
    }
}

extension Narrator: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}