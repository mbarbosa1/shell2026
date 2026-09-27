import Foundation

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
