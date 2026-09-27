import Observation
import WatchConnectivity
import WatchKit

/// What the phone asks the wrist to feel. Raw values are the wire format: keep them in sync with
/// `WatchHaptic` in the iPhone app (ShellApp/WatchLink.swift).
enum WatchHaptic: String {
    case right, left, turnAround, go, arrived, wrongWay, finished
    /// Cart distance sensor: buzz from `obstacleOn` until `obstacleOff`.
    case obstacleOn, obstacleOff
    /// The arm has the product centered; hand guiding starts.
    case productFound
    /// Hand guiding: each direction repeats until the next cue.
    case handLeft, handRight, handUp, handDown, handOnItem, handGuideOff
    /// Hand guiding: lined up with the product but short of it. Repeats like the directions.
    case handForward

    /// Turns are counted taps: right one, left two, turn around three. The rest use the watch's
    /// own patterns, which feel different from a plain tap. Hand left/right reuse the turn taps,
    /// up/down use the rising and falling patterns, and "reach further" the retry pattern, which
    /// nothing else uses. The obstacle alarm and hand directions repeat (see `WatchReceiver`);
    /// `obstacleOff` and `handGuideOff` only stop them.
    var pattern: [WKHapticType] {
        switch self {
        case .right, .handRight: [.notification]
        case .left, .handLeft: [.notification, .notification]
        case .turnAround: [.notification, .notification, .notification]
        case .go: [.start]
        case .arrived: [.stop]
        case .wrongWay, .obstacleOn: [.failure]
        case .finished: [.success]
        case .productFound: [.click, .click]
        case .handUp: [.directionUp]
        case .handDown: [.directionDown]
        case .handForward: [.retry]
        case .handOnItem: [.success, .success]
        case .obstacleOff, .handGuideOff: []
        }
    }
}

/// Takes cues from the iPhone and plays them on the wrist.
///
/// A watch app normally stops running soon after the wrist drops, and then it can't take
/// messages. An extended runtime session keeps it going for the trip; it needs the watch target's
/// Background Modes capability with a session type set (see README in this folder).
@MainActor
@Observable
final class WatchReceiver: NSObject {
    private(set) var text = "Start navigation on your iPhone."
    private(set) var isConnected = false

    /// Taps closer than this blur into one.
    private static let tapGap: Duration = .milliseconds(600)
    /// How often the obstacle alarm buzzes. Much faster and the watch drops some.
    private static let alarmGap: Duration = .milliseconds(700)
    /// How often a hand direction repeats, like a "warmer / colder" game.
    private static let handGap: Duration = .milliseconds(1400)

    @ObservationIgnored private var playing: Task<Void, Never>?
    /// The repeating obstacle buzz. It always wins: other cues don't play while it's on.
    @ObservationIgnored private var alarm: Task<Void, Never>?
    /// The repeating hand direction. Nil when not guiding.
    @ObservationIgnored private var handGuide: Task<Void, Never>?
    @ObservationIgnored private var runtime: WKExtendedRuntimeSession?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        keepRunning()
    }

    func keepRunning() {
        guard runtime?.state != .running && runtime?.state != .scheduled else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtime = session
    }

    private func receive(text: String?, haptic: WatchHaptic?) {
        if let text { self.text = text }
        guard let haptic else { return }
        switch haptic {
        case .obstacleOn:
            startAlarm()
        case .obstacleOff:
            alarm?.cancel()
            alarm = nil
        case .handLeft, .handRight, .handUp, .handDown, .handForward:
            repeatHandDirection(haptic)
        case .handOnItem, .handGuideOff:
            handGuide?.cancel()
            handGuide = nil
            play(haptic)
        default:
            play(haptic)
        }
    }

    /// Plays a cue's pattern once, unless the obstacle alarm is buzzing.
    private func play(_ haptic: WatchHaptic) {
        guard alarm == nil else { return }
        playing?.cancel()
        playing = Task { await tap(haptic.pattern) }
    }

    private func tap(_ pattern: [WKHapticType]) async {
        for (index, type) in pattern.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.tapGap) }
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(type)
        }
    }

    private func startAlarm() {
        guard alarm == nil else { return }  // already buzzing
        playing?.cancel()
        alarm = Task {
            while !Task.isCancelled {
                WKInterfaceDevice.current().play(.failure)
                try? await Task.sleep(for: Self.alarmGap)
            }
        }
    }

    private func repeatHandDirection(_ haptic: WatchHaptic) {
        handGuide?.cancel()
        handGuide = Task {
            while !Task.isCancelled {
                if alarm == nil { await tap(haptic.pattern) }
                try? await Task.sleep(for: Self.handGap)
            }
        }
    }
}

extension WatchReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let isConnected = state == .activated
        Task { @MainActor in self.isConnected = isConnected }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isConnected = session.isReachable
        Task { @MainActor in self.isConnected = isConnected }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let text = message["text"] as? String
        let haptic = (message["haptic"] as? String).flatMap(WatchHaptic.init)
        Task { @MainActor in self.receive(text: text, haptic: haptic) }
    }
}

extension WatchReceiver: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in self.runtime = nil }
    }
}
