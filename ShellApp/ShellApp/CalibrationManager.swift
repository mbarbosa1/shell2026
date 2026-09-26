import Foundation
import ARKit
import Combine

enum TrackingQuality: Equatable {
    case good
    case degraded(String)
    case unavailable

    var canMarkNode: Bool {
        if case .good = self { return true }
        return false
    }
}

/// Records a single undoable step so "Undo Last" can cleanly reverse it.
/// Undo is a stack: repeated taps walk back through every action since
/// launch, or since the last successful Restart Segment (which clears it).
///
/// newNode and newEdgeOnly are kept SEPARATE on purpose: undoing a new edge
/// created while returning to an already-existing node must never delete
/// that node — it already existed before this action, other edges may
/// reference it, and deleting it would corrupt the graph.
private enum CalibrationAction {
    case newNode(nodeId: String, edgeId: String?)              // edgeId nil only for the very first node (entrance)
    case newEdgeOnly(edgeId: String, previousLastNodeId: String)  // new connection to a PRE-EXISTING node
    case returnVisit(edgeId: String, observationId: UUID, previousLastNodeId: String)
}

final class CalibrationManager: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: Published state for the UI
    @Published var trackingQuality: TrackingQuality = .unavailable
    @Published var distanceSinceLastNode: Double = 0.0
    @Published var session = CalibrationSessionData(storeName: "Unnamed Store")
    @Published var lastMessage: String?
    @Published var liveYawDegrees: Double = 0
    @Published var segmentInterrupted: Bool = false

    /// Prior calibration files found on disk at launch. These are NEVER
    /// loaded into the active session — only listed here for read-only
    /// export. See init: mixing an old file's coordinates with a new,
    /// unaligned ARSession would silently corrupt both.
    @Published var priorSessionFiles: [URL] = []

    let arSession = ARSession()

    // MARK: Internal tracking state
    private var currentTransform: simd_float4x4?
    /// Published so the return-to-node picker can exclude the node you're
    /// currently standing at.
    @Published private(set) var lastNodeId: String?
    private var pendingBreadcrumbs: [Point2D] = []
    private var lastBreadcrumbPoint: Point2D?
    private var actionHistory: [CalibrationAction] = []

    // Minimum spacing between recorded breadcrumb points, in meters.
    private let breadcrumbSpacingMeters = 0.3

    // PLACEHOLDER. Must be re-tuned from real discrepancy numbers collected
    // during the actual walkthrough. Shared by both loop-closure discrepancy
    // checks (markReturnToNode) and restart-recovery discrepancy checks
    // (restartSegment) — same underlying question in both places: does this
    // measured position actually match where we think we are.
    private let positionDiscrepancyThresholdMeters = 1.0

    /// Each launch writes to its own timestamped file. This is deliberate:
    /// resuming into a previous file after a fresh, unaligned ARSession
    /// start would mix two unrelated coordinate systems under one graph,
    /// with no way to tell the two apart later.
    private(set) var currentSessionURL: URL

    override init() {
        currentSessionURL = Self.newSessionURL()
        super.init()
        arSession.delegate = self
        scanForPriorSessions()
    }

    private static func newSessionURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("calibration_\(stamp).json")
    }

    func start(storeName: String) {
        session.storeName = storeName
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity   // keep Y vertical; do NOT use .gravityAndHeading indoors
        arSession.run(config)
        persist()   // so "Export Current" has a real file before the first node
    }

    // MARK: - ARSessionDelegate
    // Fires continuously, every frame, for the entire lifetime of the
    // session — there is no "pause" state. Marking a node does not stop
    // this; it just reads whatever the latest value is at that moment.

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        currentTransform = frame.camera.transform
        let quality = Self.classify(frame.camera.trackingState)

        // Assign only on change — every @Published write fires
        // objectWillChange, and this runs ~60x/sec, which would otherwise
        // invalidate the whole CalibrationView every frame.
        if quality != trackingQuality {
            trackingQuality = quality
        }
        if let y = yawDegrees(), abs(y - liveYawDegrees) >= 0.5 {
            liveYawDegrees = y
        }

        switch quality {
        case .good:
            // While a segment is flagged interrupted, do NOT resume silent
            // recording just because tracking recovered — the gap itself
            // may have covered real motion (e.g. around a corner) that
            // would otherwise get saved as a straight-line cut. Require
            // an explicit "Restart Segment" from the operator first.
            guard !segmentInterrupted else { return }
            guard let pos = currentPosition() else { return }

            if let last = lastBreadcrumbPoint {
                if last.distance(to: pos) >= breadcrumbSpacingMeters {
                    pendingBreadcrumbs.append(pos)
                    lastBreadcrumbPoint = pos
                    distanceSinceLastNode = pathLength(pendingBreadcrumbs)
                }
            } else {
                lastBreadcrumbPoint = pos
            }

        case .degraded, .unavailable:
            // Only a real problem if we're actively mid-segment. Gated on
            // lastNodeId, not lastBreadcrumbPoint — the latter gets set on
            // the very first good frame of the whole app launch, before
            // any node exists, so using it here could tell the operator to
            // "return to the last confirmed node" when there isn't one yet.
            flagInterruption("Tracking interrupted mid-segment. This path can't be trusted. Walk back to the last confirmed node and tap Restart Segment.")
        }
    }

    // App backgrounded, phone call, camera taken by another app, etc. Frames
    // stop arriving entirely, so this must be flagged explicitly rather than
    // relying on a limited-tracking frame showing up afterwards.
    func sessionWasInterrupted(_ session: ARSession) {
        markTrackingLost()
        flagInterruption("AR session was interrupted (app left foreground?). Walk back to the last confirmed node and tap Restart Segment.")
    }

    // Lets ARKit try to restore the pre-interruption coordinate frame, which
    // gives restartSegment's discrepancy check a real chance of passing.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        markTrackingLost()
        let message = "AR session failed: \(error.localizedDescription). Leave and reopen calibration to start a new session."
        flagInterruption(message)
        lastMessage = message   // shown even before the first node exists
    }

    /// No more frames will arrive until the session resumes, so the last
    /// frame's quality and transform are stale. Clear them — otherwise the
    /// UI keeps reporting .good and nodes get marked at a frozen position.
    private func markTrackingLost() {
        trackingQuality = .unavailable
        currentTransform = nil
    }

    private func flagInterruption(_ message: String) {
        guard lastNodeId != nil, !segmentInterrupted else { return }
        segmentInterrupted = true
        lastMessage = message
    }

    private static func classify(_ state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .normal:
            return .good
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return .degraded("Excessive motion — slow down")
            case .insufficientFeatures: return .degraded("Low visual detail here")
            case .initializing: return .degraded("Initializing tracking")
            case .relocalizing: return .degraded("Relocalizing")
            @unknown default: return .degraded("Limited tracking")
            }
        case .notAvailable:
            return .unavailable
        }
    }

    // MARK: - Position / heading extraction

    private func currentPosition() -> Point2D? {
        guard let t = currentTransform else { return nil }
        return Point2D(x: Double(t.columns.3.x), z: Double(t.columns.3.z))
    }

    /// Heading in degrees, derived from the camera's forward direction
    /// projected onto the horizontal plane.
    ///
    /// Convention (derived on paper): 0° = the direction the camera faced at
    /// session start, positive = turned LEFT (counter-clockwise seen from
    /// above), range (-180, 180]. The ±180 wrap is therefore directly
    /// behind the start direction, not at it.
    ///
    /// STILL VERIFY ON DEVICE with the live heading readout in
    /// CalibrationView before trusting any turn-direction logic.
    /// Degenerate when the phone points nearly straight up or down (the
    /// forward vector's horizontal projection shrinks toward zero).
    func yawDegrees() -> Double? {
        guard let t = currentTransform else { return nil }
        let forwardX = -Double(t.columns.2.x)
        let forwardZ = -Double(t.columns.2.z)
        let radians = atan2(-forwardX, -forwardZ)
        return radians * 180.0 / .pi
    }

    private func pathLength(_ points: [Point2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += points[i - 1].distance(to: points[i])
        }
        return total
    }

    /// Seeds a new segment with its actual departure position, rather than
    /// starting empty and waiting for 0.3m of movement before recording
    /// anything — that gap was silently truncating the start of every edge.
    private func beginNewSegment(from pos: Point2D) {
        pendingBreadcrumbs = [pos]
        lastBreadcrumbPoint = pos
        distanceSinceLastNode = 0
        segmentInterrupted = false
    }

    // MARK: - Node marking

    /// Create a brand-new node at the current position.
    func markNewNode(name: String) {
        guard trackingQuality.canMarkNode, !segmentInterrupted, let pos = currentPosition() else {
            lastMessage = "Tracking not stable (or segment interrupted) — node NOT marked."
            return
        }

        let newNode = NodeRecord(id: UUID().uuidString, name: name, position: pos)
        var newEdgeId: String? = nil

        if let previousNodeId = lastNodeId {
            // Arrival point appended explicitly — the seed at the start of
            // beginNewSegment covers the departure end, this covers the
            // arrival end, so the edge's breadcrumb trail runs endpoint to
            // endpoint with nothing missing at either side.
            let edge = EdgeRecord(
                id: UUID().uuidString,
                fromNodeId: previousNodeId,
                toNodeId: newNode.id,
                breadcrumbs: pendingBreadcrumbs + [pos],
                bidirectional: true
            )
            session.edges.append(edge)
            newEdgeId = edge.id
        } else {
            // First node of the whole session — treated as the entrance.
            if let heading = yawDegrees() {
                session.startPose = StartPose(position: pos, headingDegrees: heading)
            }
        }

        session.nodes.append(newNode)
        actionHistory.append(.newNode(nodeId: newNode.id, edgeId: newEdgeId))

        lastNodeId = newNode.id
        beginNewSegment(from: pos)
        lastMessage = "Marked: \(name)"

        persist()
    }

    /// Close the current walk against a previously-created node, instead of
    /// creating a duplicate. Appends a VisitObservation. Does NOT overwrite
    /// or average the node's canonical position.
    func markReturnToNode(nodeId: String) {
        guard trackingQuality.canMarkNode, !segmentInterrupted, let pos = currentPosition(),
              let targetNode = session.nodes.first(where: { $0.id == nodeId }),
              let previousNodeId = lastNodeId else {
            lastMessage = "Tracking not stable (or segment interrupted), or no prior node to close from."
            return
        }
        // Returning to the node you just left would record a self-loop edge.
        guard nodeId != previousNodeId else {
            lastMessage = "You're already at \(targetNode.name) — nothing recorded."
            return
        }

        let discrepancy = pos.distance(to: targetNode.position)
        let flagged = discrepancy > positionDiscrepancyThresholdMeters
        var createdNewEdge = false

        if let idx = session.edges.firstIndex(where: {
            ($0.fromNodeId == previousNodeId && $0.toNodeId == nodeId) ||
            ($0.fromNodeId == nodeId && $0.toNodeId == previousNodeId)
        }) {
            let observation = VisitObservation(
                fromNodeId: previousNodeId,
                toNodeId: nodeId,
                arrivalPosition: pos,
                discrepancy: discrepancy,
                timestamp: Date(),
                flagged: flagged,
                diagnosticTrail: pendingBreadcrumbs + [pos]   // seed (departure) + arrival, both included
            )
            session.edges[idx].visitObservations.append(observation)
            actionHistory.append(.returnVisit(
                edgeId: session.edges[idx].id,
                observationId: observation.id,
                previousLastNodeId: previousNodeId
            ))
        } else {
            // No recorded connection between these two nodes — a genuinely
            // new physical path to an ALREADY-EXISTING node. Recorded as
            // .newEdgeOnly, never .newNode — undoing this must remove only
            // the edge, not the node itself, since the node predates this
            // action and other edges may already reference it.
            var newEdge = EdgeRecord(
                id: UUID().uuidString,
                fromNodeId: previousNodeId,
                toNodeId: nodeId,
                breadcrumbs: pendingBreadcrumbs + [pos],   // arrival point included
                bidirectional: true
            )
            // This traversal's discrepancy needs to be saved, not just
            // shown on screen — this is often the FIRST time a loop closes
            // against this node, so it's exactly the observation you'd
            // want to review later, not lose.
            let observation = VisitObservation(
                fromNodeId: previousNodeId,
                toNodeId: nodeId,
                arrivalPosition: pos,
                discrepancy: discrepancy,
                timestamp: Date(),
                flagged: flagged,
                diagnosticTrail: pendingBreadcrumbs + [pos]
            )
            newEdge.visitObservations.append(observation)
            session.edges.append(newEdge)
            actionHistory.append(.newEdgeOnly(edgeId: newEdge.id, previousLastNodeId: previousNodeId))
            createdNewEdge = true
        }

        // Both warnings can apply at once — a flagged discrepancy must not
        // hide the fact that a new edge was created.
        var messages: [String] = []
        if createdNewEdge {
            messages.append("No existing connection found — recorded as a NEW edge to \(targetNode.name). Confirm this was intended.")
        }
        if flagged {
            messages.append("Large discrepancy (\(String(format: "%.2f", discrepancy))m) returning to \(targetNode.name). Consider re-walking this section now, while you're still here.")
        }
        lastMessage = messages.isEmpty ? "Returned to \(targetNode.name)." : messages.joined(separator: "\n")

        lastNodeId = nodeId
        beginNewSegment(from: pos)

        persist()
    }

    /// Operator confirms they've physically walked back to the last
    /// confirmed node after a tracking interruption.
    ///
    /// Seeds the new segment from the phone's ACTUAL measured position, not
    /// the node's canonical position — physically returning to a spot
    /// doesn't guarantee tracking reports the same coordinates it did the
    /// first time, and seeding from the canonical value would silently
    /// paper over exactly that mismatch, inventing a connecting segment
    /// between two positions that were never actually observed together.
    ///
    /// Requires good tracking before restarting at all — restarting on bad
    /// tracking would just seed from another unreliable reading. A large
    /// discrepancy between measured and canonical position blocks
    /// continuation rather than being absorbed silently; this segment (or
    /// the calibration session) needs a real re-walk, not a soft reset.
    func restartSegment() {
        guard trackingQuality.canMarkNode, let pos = currentPosition() else {
            // NOTE: the status dot stays orange (not green) the whole time
            // segmentInterrupted is true, even once tracking itself has
            // recovered — segmentInterrupted only clears on a successful
            // restart. Don't tell the operator to wait for "green" here.
            lastMessage = "Tracking hasn't recovered yet — wait a moment and try Restart Segment again."
            return   // segmentInterrupted stays true; nothing seeded yet
        }

        guard let lastId = lastNodeId, let lastNode = session.nodes.first(where: { $0.id == lastId }) else {
            // No prior node exists at all — shouldn't normally happen now
            // that the interruption trigger is gated on lastNodeId != nil,
            // but handle it safely rather than crash.
            beginNewSegment(from: pos)
            return
        }

        let discrepancy = pos.distance(to: lastNode.position)
        let blocked = discrepancy > positionDiscrepancyThresholdMeters

        session.restartEvents.append(RestartEvent(
            nodeId: lastNode.id,
            measuredPosition: pos,
            discrepancy: discrepancy,
            timestamp: Date(),
            blocked: blocked
        ))

        if blocked {
            lastMessage = "Measured position is \(String(format: "%.2f", discrepancy))m from \(lastNode.name)'s recorded position — too large to trust as the same spot. Don't continue this segment; re-walk from a known-good point or restart calibration."
            // segmentInterrupted stays true on purpose — this is not resolved.
            persist()
            return
        }

        beginNewSegment(from: pos)   // seeded from MEASURED position, not lastNode.position

        // Undo must not be able to cross this recovery boundary — the old
        // trail (pre-interruption) and the new one (post-restart) were
        // measured against potentially different readings at the same
        // physical spot. Joining them on undo, as the normal undo logic
        // does, would assume those endpoints match when they may not.
        // Clearing history here is the simple fix: nothing before this
        // point can be undone anymore.
        actionHistory.removeAll()

        lastMessage = "Segment restarted at \(lastNode.name) (measured discrepancy \(String(format: "%.2f", discrepancy))m). Earlier undo history was cleared."
        persist()
    }

    func undoLast() {
        guard let action = actionHistory.popLast() else {
            lastMessage = "Nothing to undo."
            return
        }

        // Undoing an action does not resolve an unobserved tracking gap —
        // if the current trail was already flagged interrupted, it still
        // is after undo. Clearing this unconditionally would let recording
        // silently resume across a gap the operator never actually
        // re-walked, which is the exact corruption this flag exists to
        // block.
        let wasInterrupted = segmentInterrupted

        // Whatever's been walked SINCE the action being undone (post-mark
        // trail) needs to be preserved and reattached, not discarded — the
        // seed point at index 0 is dropped to avoid duplicating the node
        // position both endpoints already share.
        let postMarkTrail: [Point2D] = pendingBreadcrumbs.count > 1 ? Array(pendingBreadcrumbs.dropFirst()) : []

        switch action {
        case .newNode(let nodeId, let edgeId):
            if let edgeId = edgeId, let edgeIdx = session.edges.firstIndex(where: { $0.id == edgeId }) {
                let edge = session.edges[edgeIdx]
                pendingBreadcrumbs = edge.breadcrumbs + postMarkTrail
                lastBreadcrumbPoint = pendingBreadcrumbs.last
                lastNodeId = edge.fromNodeId
                session.edges.remove(at: edgeIdx)
            } else {
                // Undoing the very first node — nothing existed before it.
                lastNodeId = nil
                pendingBreadcrumbs = []
                lastBreadcrumbPoint = nil
                session.startPose = nil
            }
            session.nodes.removeAll { $0.id == nodeId }
            distanceSinceLastNode = pathLength(pendingBreadcrumbs)
            lastMessage = "Undid node creation."

        case .newEdgeOnly(let edgeId, let previousLastNodeId):
            guard let edgeIdx = session.edges.firstIndex(where: { $0.id == edgeId }) else {
                lastMessage = "Undo failed: edge not found. Nothing changed."
                return
            }
            let edge = session.edges[edgeIdx]
            pendingBreadcrumbs = edge.breadcrumbs + postMarkTrail
            lastBreadcrumbPoint = pendingBreadcrumbs.last
            // Node is NOT removed — it existed before this action.
            session.edges.remove(at: edgeIdx)
            lastNodeId = previousLastNodeId
            distanceSinceLastNode = pathLength(pendingBreadcrumbs)
            lastMessage = "Undid new connection (existing node kept)."

        case .returnVisit(let edgeId, let observationId, let previousLastNodeId):
            guard let edgeIdx = session.edges.firstIndex(where: { $0.id == edgeId }),
                  let obsIdx = session.edges[edgeIdx].visitObservations.firstIndex(where: { $0.id == observationId }) else {
                lastMessage = "Undo failed: observation not found. Nothing changed."
                return
            }
            let obs = session.edges[edgeIdx].visitObservations[obsIdx]
            pendingBreadcrumbs = obs.diagnosticTrail + postMarkTrail
            lastBreadcrumbPoint = pendingBreadcrumbs.last
            session.edges[edgeIdx].visitObservations.remove(at: obsIdx)
            lastNodeId = previousLastNodeId
            distanceSinceLastNode = pathLength(pendingBreadcrumbs)
            lastMessage = "Undid return-to-node."
        }

        segmentInterrupted = wasInterrupted
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(session)
            try data.write(to: currentSessionURL, options: .atomic)
        } catch {
            lastMessage = "SAVE FAILED: \(error.localizedDescription)"
        }
    }

    /// Lists prior calibration files for read-only export. These are never
    /// read back into `session` — a fresh ARSession has no relationship to
    /// their coordinate frame, so loading one in would silently mix two
    /// unrelated origins under one graph.
    private func scanForPriorSessions() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        priorSessionFiles = files
            .filter { $0.lastPathComponent.hasPrefix("calibration_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func exportFileURL() -> URL {
        currentSessionURL
    }

    /// Starts a fresh session in a NEW timestamped file. The file for the
    /// session being reset is left on disk as-is (it shows up under Prior
    /// Sessions), so an accidental reset never destroys walked data.
    /// Confirm with the user before calling.
    func resetActiveSession() {
        currentSessionURL = Self.newSessionURL()
        scanForPriorSessions()
        session = CalibrationSessionData(storeName: session.storeName)
        lastNodeId = nil
        pendingBreadcrumbs = []
        lastBreadcrumbPoint = nil
        actionHistory = []
        distanceSinceLastNode = 0
        segmentInterrupted = false
        persist()
    }
}
