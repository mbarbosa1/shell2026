import WatchConnectivity

/// What the watch plays on the user's wrist. Turns are counted taps, so they can't be mixed up
/// without looking: right is one tap, left two, turn around three.
///
/// The raw values are the messages' wire format: keep them in sync with `WatchHaptic` in the
/// watch app (ShellWatch/WatchReceiver.swift).
enum WatchHaptic: String {
    case right, left, turnAround, go, arrived, wrongWay, finished
}

/// Sends navigation cues to the watch app. Live messages only: a turn that arrives late is worse
/// than none, so nothing is queued while the watch isn't reachable.
final class WatchLink: NSObject, WCSessionDelegate {
    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// True when the watch app is running and can take a cue right now.
    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func send(_ haptic: WatchHaptic?, text: String) {
        guard isReachable else { return }
        var message: [String: Any] = ["text": text]
        if let haptic { message["haptic"] = haptic.rawValue }
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            print("⌚️ Couldn't send \(haptic?.rawValue ?? "text") to the watch: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Happens when the user switches watches: connect to the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
