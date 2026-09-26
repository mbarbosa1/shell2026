import Foundation

/// ElevenLabs settings, read from the app's environment variables.
///
/// An iOS app can't read the repo's `.env` file, so Xcode passes the values in instead:
/// Product → Scheme → Edit Scheme… → Run → Arguments → Environment Variables.
/// Add each name below there and paste its value from `.env`. The scheme lives in
/// `xcuserdata/`, which git ignores, so the values stay out of the repo.
///
/// These are only set when the app is launched from Xcode (⌘R).
enum VoiceConfig {
    /// `ELEVENLABS_AGENT_ID`: the agent to talk to, from the ElevenLabs dashboard (Agent → Settings).
    static var agentID: String? { value(named: "ELEVENLABS_AGENT_ID") }

    /// `ELEVENLABS_API_KEY`: only needed if the agent is private (authentication turned on).
    /// Debug builds only. A shipped app must get conversation tokens from a backend instead,
    /// because anyone can pull an API key out of an app.
    static var apiKey: String? { value(named: "ELEVENLABS_API_KEY") }

    private static func value(named name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }
}
