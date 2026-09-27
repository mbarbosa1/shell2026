import Foundation

/// Counts suitable attempts, never video frames. Values are provisional usability
/// settings; they make no claim about recognition accuracy.
public struct RecognitionRoutingPolicy: Sendable {
    public let emptyAttempts: Int
    public let minimumAttemptInterval: TimeInterval
    public let unrelatedTextDuration: TimeInterval
    public let maximumAttemptGap: TimeInterval

    public init(emptyAttempts: Int = 3, minimumAttemptInterval: TimeInterval = 1,
                unrelatedTextDuration: TimeInterval = 8, maximumAttemptGap: TimeInterval = 3) {
        self.emptyAttempts = max(1, emptyAttempts)
        self.minimumAttemptInterval = minimumAttemptInterval.isFinite ? max(0, minimumAttemptInterval) : 1
        self.unrelatedTextDuration = unrelatedTextDuration.isFinite ? max(0, unrelatedTextDuration) : 8
        self.maximumAttemptGap = maximumAttemptGap.isFinite ? max(0, maximumAttemptGap) : 3
    }
}

public struct RecognitionPathTransition: Sendable, Equatable, Identifiable, Codable {
    public enum Reason: String, Sendable, Codable { case noReadableText, unrelatedText }
    public let id: UUID
    public let timestamp: TimeInterval
    public let reason: Reason
    public let suitableAttempts: Int
    public var message: String {
        "I couldn’t identify this item from its writing. Now checking its appearance."
    }
}

struct TextTrial: Sendable {
    private(set) var suitableAttempts = 0
    private var emptyCount = 0
    private var firstAttempt: TimeInterval?
    private var lastAttempt: TimeInterval?

    mutating func reset() { self = TextTrial() }

    mutating func observe(at time: TimeInterval, suitable: Bool, hasText: Bool,
                          usefulMatch: Bool, policy: RecognitionRoutingPolicy) -> RecognitionPathTransition.Reason? {
        guard time.isFinite else { reset(); return nil }
        guard suitable, !usefulMatch else { reset(); return nil }
        if let lastAttempt {
            guard time > lastAttempt else { return nil }
            if time - lastAttempt > policy.maximumAttemptGap { reset() }
            else if time - lastAttempt < policy.minimumAttemptInterval { return nil }
        }
        if firstAttempt == nil { firstAttempt = time }
        lastAttempt = time
        suitableAttempts += 1
        emptyCount = hasText ? 0 : emptyCount + 1
        if emptyCount >= policy.emptyAttempts { return .noReadableText }
        if suitableAttempts >= policy.emptyAttempts,
           time - (firstAttempt ?? time) >= policy.unrelatedTextDuration { return .unrelatedText }
        return nil
    }
}

/// A monotonic deadline shared by every recognition path for one queue entry.
/// `startedAt` is the previous entry's acceptance time (the first entry uses Start).
public struct ScanDeadline: Sendable, Equatable {
    public let startedAt: TimeInterval
    public let duration: TimeInterval
    public init(startedAt: TimeInterval, duration: TimeInterval = 60) {
        self.startedAt = startedAt
        self.duration = duration.isFinite ? max(0, duration) : 60
    }
    public func remaining(at time: TimeInterval) -> TimeInterval { max(0, duration - max(0, time - startedAt)) }
    public func hasExpired(at time: TimeInterval) -> Bool { remaining(at: time) <= 0 }
    public static let expiredMessage = "A minute has passed. Move to the next step in the database."
}
