import ARKit
import Foundation
import Observation
import simd

/// Walks the user through a planned route by measuring how far they've gone along it.
///
/// The route is cut into legs: straight runs from one decision point to the next (a turn, where a
/// stop begins, the end of a lane, the cashier). A leg's length is the sum of its edges' walked
/// lengths, which were measured, so they're trusted over the drawn node positions. ARKit (or a
/// simulated walk) says where the phone is; the distance moved since the leg began, along the
/// leg's direction, is how far along it the user is. Getting within `arrivalTolerance` of the
/// leg's length is arriving at its end node.
///
/// ARKit's frame is turned from the map's by an unknown angle. It's learned from the first leg
/// (the direction actually walked vs the map's direction for that leg) and relearned at the end of
/// every leg, so drift doesn't build up. Once it's known, heading the wrong way after a turn is
/// caught within a couple of meters.
///
/// At a stop the navigator waits: the camera takes over to find the items. Once they're all in the
/// cart (or the stop is skipped), it plans again from where the user is, for what's left.
///
/// Every instruction goes out through `announce`: spoken, and played on the watch (`WatchHaptic`).
@MainActor
@Observable
final class RouteNavigator {
    enum Turn {
        case straight, left, right, around

        /// Nil for straight on.
        var instruction: String? {
            switch self {
            case .straight: nil
            case .left: "Turn left"
            case .right: "Turn right"
            case .around: "Turn around"
            }
        }

        var haptic: WatchHaptic {
            switch self {
            case .straight: .go
            case .left: .left
            case .right: .right
            case .around: .turnAround
            }
        }
    }

    struct Leg {
        /// Indices into the plan's path of the node the leg starts at and the one it ends at.
        let start: Int
        let end: Int
        let meters: Double
        /// Unit vector on the map, from the start node to the end node.
        let direction: SIMD2<Double>
        /// Unit vector on the map of the last edge, i.e. which way the user faces on arriving.
        let arrivalDirection: SIMD2<Double>
        /// The turn at the end node. Nil at the end of the route.
        let turnAfter: Turn?
        /// The stop that begins at the end node.
        let stop: RoutePlanner.Stop?
    }

    enum Phase {
        case walking
        /// Stopped where `activeStop` begins, while the camera looks for its items.
        case atStop
        /// Heading away from the current leg. Walking back toward its start clears it.
        case wrongWay
        case finished
    }

    /// How close to a leg's end counts as there. ARKit is good to a few centimeters a meter, so
    /// this mostly covers where exactly the user stops.
    static let arrivalTolerance = 0.6
    /// How far ahead a turn or stop is announced.
    static let warnAhead = 3.0
    /// How far into a leg before its direction is checked, and how far off it may be.
    static let checkAfter = 1.5
    static let wrongWayDegrees = 60.0

    let map: StoreMap
    /// True when positions come from `simulateWalk` instead of ARKit.
    let isSimulated: Bool
    private(set) var plan = RoutePlanner.Plan(stops: [], path: [], meters: 0, unlocated: [], unmapped: [])
    private(set) var legs: [Leg] = []
    private(set) var legIndex = 0
    private(set) var phase: Phase = .walking
    private(set) var activeStop: RoutePlanner.Stop?
    /// Meters left on the current leg.
    private(set) var metersLeft = 0.0
    /// The last thing announced, shown big on screen.
    private(set) var instruction = ""
    /// Why ARKit isn't tracking well right now, or nil.
    private(set) var trackingNote: String?

    /// The part of the path still to walk, from the start of the current leg.
    var remainingPath: [String] {
        guard legs.indices.contains(legIndex) else { return phase == .finished ? [] : plan.path }
        return Array(plan.path[legs[legIndex].start...])
    }

    @ObservationIgnored private let remainingItems: () -> [RoutePlanner.Item]
    @ObservationIgnored private let announce: (String, WatchHaptic?) -> Void
    /// `AppModel`'s ARKit session, followed by `PositionTracker` on a real walk.
    @ObservationIgnored private let session: ARSession
    /// Called once the route reaches the cashier.
    @ObservationIgnored private let onFinish: () -> Void
    @ObservationIgnored private let positions: [String: SIMD2<Double>]
    @ObservationIgnored private let edgeMeters: [String: [String: Double]]
    @ObservationIgnored private var tracker: PositionTracker?
    /// Latest position in ARKit's frame, seen from above (see `PositionTracker`).
    @ObservationIgnored private var position: SIMD2<Double>?
    /// Where the current leg began, in ARKit's frame.
    @ObservationIgnored private var legOrigin: SIMD2<Double>?
    /// Where the active stop began, in ARKit's frame.
    @ObservationIgnored private var stopOrigin: SIMD2<Double>?
    /// Radians to turn a direction in ARKit's frame by to get the map's. Nil until a leg's been walked.
    @ObservationIgnored private var alignment: Double?
    /// The map direction last walked, so a new plan can start with the right turn.
    @ObservationIgnored private var heading: SIMD2<Double>?
    @ObservationIgnored private var hasWarned = false
    /// Items whose stop was skipped. Left out when planning again.
    @ObservationIgnored private var skipped: Set<String> = []

    init(map: StoreMap, simulated: Bool, session: ARSession,
         remainingItems: @escaping () -> [RoutePlanner.Item],
         announce: @escaping (String, WatchHaptic?) -> Void,
         onFinish: @escaping () -> Void) {
        self.map = map
        self.isSimulated = simulated
        self.session = session
        self.remainingItems = remainingItems
        self.announce = announce
        self.onFinish = onFinish
        positions = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, SIMD2($0.x, $0.y)) })
        var edgeMeters: [String: [String: Double]] = [:]
        for edge in map.edges {
            let meters = map.length(of: edge)
            edgeMeters[edge.from, default: [:]][edge.to] = meters
            edgeMeters[edge.to, default: [:]][edge.from] = meters
        }
        self.edgeMeters = edgeMeters
    }

    func start() {
        if isSimulated {
            position = .zero
        } else {
            let tracker = PositionTracker(session: session)
            tracker.onPosition = { [weak self] in self?.update(position: $0) }
            tracker.onStatus = { [weak self] in self?.trackingNote = $0 }
            tracker.start()
            self.tracker = tracker
        }
        follow(RoutePlanner(map: map).plan(for: remainingItems()), from: position)
    }

    func stop() {
        tracker?.stop()
        tracker = nil
    }

    /// Call when the list changes. At a stop, moves on once all of its items are in the cart.
    func itemsChanged() {
        guard phase == .atStop, let stop = activeStop else { return }
        let left = Set(remainingItems().map(\.name))
        guard !Self.items(of: stop).contains(where: left.contains) else { return }
        resume()
    }

    /// Moves on from the active stop without its items. They aren't routed to again this trip.
    func skipStop() {
        guard let stop = activeStop else { return }
        skipped.formUnion(Self.items(of: stop))
        resume()
    }

    // MARK: Tracking

    func update(position p: SIMD2<Double>) {
        position = p
        guard phase == .walking || phase == .wrongWay, legs.indices.contains(legIndex) else { return }
        guard let origin = legOrigin else {
            legOrigin = p
            return
        }
        let leg = legs[legIndex]
        let moved = p - origin
        let distance = simd_length(moved)
        var along = distance
        if let alignment {
            let expected = rotate(leg.direction, by: -alignment)
            along = simd_dot(moved, expected)
            let isOff = distance > Self.checkAfter
                && simd_dot(moved / distance, expected) < cos(Self.wrongWayDegrees * .pi / 180)
            switch (phase, isOff) {
            case (.walking, true):
                phase = .wrongWay
                say("Wrong way. Turn around and go back.", haptic: .wrongWay)
                return
            case (.wrongWay, true):
                return
            case (.wrongWay, false):
                phase = .walking
                say("Back on track. " + goText(leg, after: .straight), haptic: .go)
            default:
                break
            }
        }

        metersLeft = max(leg.meters - along, 0)
        if !hasWarned, leg.meters > Self.warnAhead + 2, metersLeft <= Self.warnAhead {
            hasWarned = true
            if let warning = warning(for: leg) { say(warning, haptic: nil) }
        }
        if metersLeft <= Self.arrivalTolerance { arrive(at: p) }
    }

    private func arrive(at p: SIMD2<Double>) {
        let leg = legs[legIndex]
        let moved = p - (legOrigin ?? p)
        if simd_length(moved) > 2 {
            alignment = atan2(leg.direction.y, leg.direction.x) - atan2(moved.y, moved.x)
        }
        heading = leg.arrivalDirection
        legOrigin = p

        if let stop = leg.stop {
            reach(stop)
            return
        }
        legIndex += 1
        guard legs.indices.contains(legIndex) else {
            finish()
            return
        }
        hasWarned = false
        metersLeft = legs[legIndex].meters
        let turn = leg.turnAfter ?? .straight
        say("\(spokenName(plan.path[leg.end])). " + goText(legs[legIndex], after: turn), haptic: turn.haptic)
    }

    private func reach(_ stop: RoutePlanner.Stop) {
        phase = .atStop
        activeStop = stop
        stopOrigin = position
        metersLeft = 0
        let items = ListFormatter.localizedString(byJoining: Self.items(of: stop))
        say("Stop. You're at \(Self.aisles(of: stop)) for \(items). Tell me when it's in the cart.", haptic: .arrived)
    }

    private func finish() {
        phase = .finished
        metersLeft = 0
        say("You've reached the \(spokenName(map.cashierId).lowercased()).", haptic: .finished)
        stop()
        onFinish()
    }

    // MARK: Planning

    private func follow(_ plan: RoutePlanner.Plan, from origin: SIMD2<Double>?) {
        self.plan = plan
        let route = route(plan)
        legs = route.legs
        legIndex = 0
        hasWarned = false
        legOrigin = origin
        if let stop = route.stopAtStart {
            reach(stop)
            return
        }
        guard let first = legs.first else {
            finish()
            return
        }
        phase = .walking
        metersLeft = first.meters
        let turn = heading.map { Self.turn(from: $0, to: first.direction) } ?? .straight
        say(goText(first, after: turn), haptic: turn.haptic)
    }

    private func resume() {
        guard let stop = activeStop else { return }
        activeStop = nil
        let (node, origin) = whereStopped(in: stop)
        let items = remainingItems().filter { !skipped.contains($0.name) }
        follow(RoutePlanner(map: map).plan(for: items, from: node), from: origin)
    }

    /// The node the user is at after a stop, and where it is in ARKit's frame. In a lane the cart
    /// may have moved along it while the camera looked, so it's the lane node nearest the distance
    /// driven since the lane began.
    private func whereStopped(in stop: RoutePlanner.Stop) -> (node: String, origin: SIMD2<Double>?) {
        let lane = stop.path
        guard lane.count > 1, let alignment, let origin = stopOrigin, let p = position else {
            return (lane[0], position)
        }
        let direction = rotate(unitVector(from: lane[0], to: lane[lane.count - 1]), by: -alignment)
        let along = simd_dot(p - origin, direction)
        var reached = [0.0]
        for i in 1..<lane.count { reached.append(reached[i - 1] + edgeLength(lane[i - 1], lane[i])) }
        let k = reached.indices.min { abs(reached[$0] - along) < abs(reached[$1] - along) } ?? 0
        if k > 0 { heading = unitVector(from: lane[k - 1], to: lane[k]) }
        return (lane[k], origin + direction * reached[k])
    }

    /// Cuts the plan's path into legs, ending one wherever there's a turn, a stop begins, or a
    /// lane ends. `stopAtStart` is a stop that begins where the path does.
    private func route(_ plan: RoutePlanner.Plan) -> (legs: [Leg], stopAtStart: RoutePlanner.Stop?) {
        let path = plan.path
        var entries: [Int: RoutePlanner.Stop] = [:]
        var laneEnds: Set<Int> = []
        var cursor = 0
        for stop in plan.stops {
            guard let i = (cursor..<path.count).first(where: { path[$0...].starts(with: stop.path) }) else { continue }
            entries[i] = stop
            laneEnds.insert(i + stop.path.count - 1)
            cursor = i + stop.path.count - 1
        }
        guard path.count >= 2 else { return ([], entries[0]) }

        func direction(_ a: Int, _ b: Int) -> SIMD2<Double> { unitVector(from: path[a], to: path[b]) }
        var legs: [Leg] = []
        var start = 0
        var meters = 0.0
        for i in 1..<path.count {
            meters += edgeLength(path[i - 1], path[i])
            let turn = i < path.count - 1 ? Self.turn(from: direction(i - 1, i), to: direction(i, i + 1)) : nil
            guard turn != .straight || entries[i] != nil || laneEnds.contains(i) else { continue }
            legs.append(Leg(start: start, end: i, meters: meters, direction: direction(start, i),
                            arrivalDirection: direction(i - 1, i), turnAfter: turn, stop: entries[i]))
            start = i
            meters = 0
        }
        return (legs, entries[0])
    }

    // MARK: Words

    private func say(_ text: String, haptic: WatchHaptic?) {
        instruction = text
        announce(text, haptic)
    }

    /// "Turn left, then go straight 12 meters to aisle 14."
    private func goText(_ leg: Leg, after turn: Turn) -> String {
        let meters = max(Int(leg.meters.rounded()), 1)
        let target = if let stop = leg.stop {
            " to \(Self.aisles(of: stop))"
        } else if leg.end == plan.path.count - 1 {
            " to the \(spokenName(plan.path[leg.end]).lowercased())"
        } else {
            ""
        }
        return (turn.instruction.map { "\($0), then go" } ?? "Go")
            + " straight \(meters == 1 ? "1 meter" : "\(meters) meters")\(target)."
    }

    private func warning(for leg: Leg) -> String? {
        let ahead = "In \(Int(Self.warnAhead)) meters, "
        if let stop = leg.stop { return ahead + "you'll reach \(Self.aisles(of: stop))." }
        guard let turn = leg.turnAfter else {
            return ahead + "you'll reach the \(spokenName(plan.path[leg.end]).lowercased())."
        }
        return turn.instruction.map { ahead + $0.lowercased() + "." }
    }

    /// "16/17 Front" reads as "16 and 17 Front".
    private func spokenName(_ id: String) -> String {
        (map.node(id)?.name ?? id).replacingOccurrences(of: "/", with: " and ")
    }

    /// "aisle 14" or "aisles 14 and 15", from locations like "G14".
    private static func aisles(of stop: RoutePlanner.Stop) -> String {
        var numbers: [String] = []
        for scan in stop.scans {
            let number = String(scan.location.drop(while: \.isLetter))
            if !numbers.contains(number) { numbers.append(number) }
        }
        return numbers.count == 1 ? "aisle \(numbers[0])" : "aisles " + ListFormatter.localizedString(byJoining: numbers)
    }

    private static func items(of stop: RoutePlanner.Stop) -> [String] {
        stop.scans.flatMap(\.itemNames)
    }

    // MARK: Geometry

    static func turn(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Turn {
        guard a != .zero, b != .zero else { return .straight }
        // Map y runs up, so a positive angle is counterclockwise: a left turn.
        let degrees = atan2(a.x * b.y - a.y * b.x, simd_dot(a, b)) * 180 / .pi
        switch abs(degrees) {
        case ..<30: return .straight
        case 150...: return .around
        default: return degrees > 0 ? .left : .right
        }
    }

    private func unitVector(from a: String, to b: String) -> SIMD2<Double> {
        guard let p = positions[a], let q = positions[b], p != q else { return .zero }
        return simd_normalize(q - p)
    }

    private func edgeLength(_ a: String, _ b: String) -> Double {
        if let meters = edgeMeters[a]?[b] { return meters }
        guard let p = positions[a], let q = positions[b] else { return 0 }
        return simd_distance(p, q)
    }

    private func rotate(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        SIMD2(v.x * cos(angle) - v.y * sin(angle), v.x * sin(angle) + v.y * cos(angle))
    }

    // MARK: Simulated walking

    /// Moves `meters` along the current leg, as if walking it.
    func simulateWalk(_ meters: Double) {
        guard legs.indices.contains(legIndex) else { return }
        simulateMove(meters, along: rotate(legs[legIndex].direction, by: -(alignment ?? 0)))
    }

    func simulateWalkToNext() {
        simulateWalk(metersLeft + 0.1)
    }

    /// Walks off at right angles to the leg, to try the wrong-way warning.
    func simulateWrongTurn() {
        guard legs.indices.contains(legIndex) else { return }
        simulateMove(2.5, along: rotate(legs[legIndex].direction, by: .pi / 2 - (alignment ?? 0)))
    }

    /// Walks back to where the current leg began.
    func simulateGoBack() {
        guard let origin = legOrigin, let p = position, p != origin else { return }
        simulateMove(simd_distance(p, origin), along: simd_normalize(origin - p))
    }

    /// Steps a quarter meter at a time, so warnings fire where they would on foot.
    private func simulateMove(_ meters: Double, along direction: SIMD2<Double>) {
        guard isSimulated else { return }
        let leg = legIndex
        var left = meters
        while left > 0, legIndex == leg, phase == .walking || phase == .wrongWay {
            let step = min(0.25, left)
            left -= step
            update(position: (position ?? .zero) + direction * step)
        }
    }
}
