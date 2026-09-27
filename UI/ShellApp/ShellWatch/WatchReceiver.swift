import Observation
import WatchConnectivity
import WatchKit

/// What the phone asks the wrist to feel. Raw values are the wire format: keep them in sync with
/// `WatchHaptic` in the iPhone app (ShellApp/WatchLink.swift).
enum WatchHaptic: String {
    case right, left, turnAround, go, arrived, wrongWay, finished

    /// Turns are counted taps: right one, left two, turn around three. The rest use the watch's
    /// own patterns, which feel different from a plain tap.
    var pattern: [WKHapticType] {
        switch self {
        case .right: [.notification]
        case .left: [.notification, .notification]
        case .turnAround: [.notification, .notification, .notification]
        case .go: [.start]
        case .arrived: [.stop]
        case .wrongWay: [.failure]
        case .finished: [.success]
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

    @ObservationIgnored private var playing: Task<Void, Never>?
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
        playing?.cancel()
        playing = Task {
            for (index, type) in haptic.pattern.enumerated() {
                if index > 0 { try? await Task.sleep(for: Self.tapGap) }
                guard !Task.isCancelled else { return }
                WKInterfaceDevice.current().play(type)
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
