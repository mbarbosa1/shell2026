import Foundation

// MARK: - Core Data Model
//
// Frozen architecture (see design discussion):
// - Nodes store a canonical (x, z) position, set once, at first visit.
// - Edges store a continuous breadcrumb trail of (x, z) points, not a single
//   distance/heading scalar — this lets navigation project onto curved paths
//   and compute forward/lateral progress correctly.
// - Revisiting a node (closing a loop) appends a VisitObservation. It does
//   NOT overwrite or average the node's canonical position — silently
//   merging coordinates would hide real calibration error instead of
//   surfacing it.
// - No artificial "checkpoint-only" node type: every node is a real,
//   named location. Fine-grained progress along long segments comes from
//   the breadcrumb trail itself, not from extra nodes.

struct Point2D: Codable, Equatable {
    var x: Double
    var z: Double

    func distance(to other: Point2D) -> Double {
        let dx = x - other.x
        let dz = z - other.z
        return (dx * dx + dz * dz).squareRoot()
    }
}

extension Array where Element == Point2D {
    /// Total walked distance along the points, in meters.
    var pathLength: Double {
        zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}

struct VisitObservation: Codable, Identifiable {
    var id: UUID = UUID()
    let fromNodeId: String         // which node this traversal departed from
    let toNodeId: String           // which node this traversal arrived at (the one being closed against)
    let arrivalPosition: Point2D
    let discrepancy: Double        // meters, vs. toNodeId's canonical position
    let timestamp: Date
    let flagged: Bool              // discrepancy exceeded threshold at capture time
    var diagnosticTrail: [Point2D] = []  // raw path on THIS pass, seeded with departure and
                                          // arrival points — review only, not used by navigation
}

struct EdgeRecord: Codable, Identifiable {
    let id: String
    let fromNodeId: String
    let toNodeId: String
    var breadcrumbs: [Point2D]     // recorded once, on first traversal of this connection
    var bidirectional: Bool
    var visitObservations: [VisitObservation] = []
}

struct NodeRecord: Codable, Identifiable {
    let id: String
    var name: String
    let position: Point2D          // canonical position, set once, at first visit
}

struct StartPose: Codable {
    let position: Point2D
    let headingDegrees: Double
    // 0° = direction faced when the AR session started, positive = LEFT,
    // range (-180, 180]. Sign verified on device. See
    // CalibrationManager.yawDegrees().
}

/// A durable record of each "Restart Segment" recovery, kept for later
/// review — not just shown as a transient on-screen message. Lets you see
/// after the fact how much measured drift accumulated at every recovery
/// point across the whole walkthrough.
struct RestartEvent: Codable {
    let nodeId: String
    let measuredPosition: Point2D   // actual measured position at restart, NOT the node's canonical position
    let discrepancy: Double
    let timestamp: Date
    let blocked: Bool               // true if discrepancy exceeded threshold and continuation was blocked
}

struct CalibrationSessionData: Codable {
    var storeName: String
    var startPose: StartPose?
    var nodes: [NodeRecord] = []
    var edges: [EdgeRecord] = []
    var restartEvents: [RestartEvent] = []
    /// The cameraToPivotOffsetMeters every position in this session was
    /// recorded with. nil only in files that predate the setting.
    var pivotOffsetMeters: Double?
}
