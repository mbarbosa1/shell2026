import Foundation
import simd

/// The store as a walkable graph: named nodes at (x, y) positions in meters, edges between the
/// ones you can walk straight between, and where to scan for each store location ("G44").
///
/// Built from calibration sessions fitted together (see `Survey`). Route planning uses edge lengths;
/// `RouteNavigator` also uses positions, to tell which way each turn goes.
struct StoreMap {
    enum Kind {
        case start, cashier, walkway, scan
    }

    /// Which way the camera looks to scan a shelf, facing the way the cart is pushed. The arm
    /// turns the phone to it (`ArmController.face`).
    enum Side: String {
        case left, right, ahead

        /// The same shelf, walked the other way.
        var flipped: Side {
            switch self {
            case .left: .right
            case .right: .left
            case .ahead: .ahead
            }
        }
    }

    struct Node: Identifiable {
        let id: String
        let name: String
        let x: Double
        let y: Double
        var kind: Kind = .walkway
    }

    struct Edge {
        let from: String
        let to: String
        /// Walked length in meters. Nil uses the straight line between the two nodes.
        var meters: Double? = nil
    }

    /// One way to pick up a location: stop at a node and scan, or drive along a lane scanning
    /// the whole way (aisle 13's items can be anywhere between node 2 and node 8).
    struct Visit {
        /// One node to stop at, or the nodes driven through in order while scanning.
        let path: [String]
        /// Nil until it's checked which way that shelf faces.
        var side: Side? = nil

        static func stop(_ node: String, scanning side: Side? = nil) -> Visit {
            Visit(path: [node], side: side)
        }

        /// The lane in both directions, so the planner can enter from whichever end is closer.
        /// `side` is for walking `nodes` in the order given; walking them backwards swaps it.
        static func lane(_ nodes: [String], scanning side: Side? = nil) -> [Visit] {
            [Visit(path: nodes, side: side), Visit(path: nodes.reversed(), side: side?.flipped)]
        }
    }

    let nodes: [Node]
    let edges: [Edge]
    /// Store location ("G44", block + aisle, same as `ItemDescribing.location`) → the ways to
    /// pick it up. The planner picks whichever makes the trip shortest.
    let stops: [String: [Visit]]
    let startId: String
    let cashierId: String

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    func length(of edge: Edge) -> Double {
        if let meters = edge.meters { return meters }
        guard let a = node(edge.from), let b = node(edge.to) else { return .infinity }
        return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}


// MARK: - Target Waterford Lakes

extension StoreMap {
    /// Target Waterford Lakes, from four calibration sessions on Sep 26, 2026 (in Calibration/):
    /// - `target-full-walk` (calibration_2026-09-27T03-34-34Z): the grocery section and the aisles
    ///   from 14/15 to 34/35, with repeat laps. Its node numbers are the map's grocery node ids.
    /// - `target-grocery` (calibration_2026-09-26T23-56-11Z): the grocery section again.
    /// - `target-store-walk` (calibration_2026-09-26T20-14-37Z): the entrance to node 1, and the
    ///   front and back ends of aisles 14/15 to 34/35.
    /// - `target-cashier` (calibration_2026-09-27T00-05-10Z): node 1 to the cashier.
    ///
    /// Every walk in them measures a stretch of the store, and the map is the best fit of all of
    /// them together (see `Survey`), so another session only makes it better.
    ///
    /// Node 1 is the only way into the grocery section, so every route starts with the same walk
    /// from the entrance and ends with the same walk to the cashier.
    ///
    /// Drawn like the Target app's map: the back wall on the left, aisle numbers growing up the
    /// map, the entrance at the bottom right.
    static let target = target(loading: CalibrationFile.bundled)

    /// The aisle pairs from 14/15 up, whose front and back ends are nodes ("16_17Front").
    static let aislePairs = stride(from: 14, through: 34, by: 2).map { "\($0)_\($0 + 1)" }

    static func target(loading load: (String) -> CalibrationFile?) -> StoreMap {
        guard let survey = targetSurvey(loading: load), let cashier = load("target-cashier") else {
            assertionFailure("The Target calibration files are missing from the app bundle")
            return StoreMap(nodes: [], edges: [], stops: [:], startId: "entrance", cashierId: "cashier")
        }

        var names = [
            "entrance": "Entrance", "turn1": "Turn 1", "checkpoint1": "Checkpoint 1",
            "checkpoint2": "Checkpoint 2", "checkpoint3": "Checkpoint 3", "checkpoint4": "Checkpoint 4",
            "44End": "Aisle 44 End", "cashier": "Cashier",
        ]
        for n in 1...7 { names["\(n)"] = "Node \(n)" }
        for pair in aislePairs {
            let label = pair.replacingOccurrences(of: "_", with: "/")
            names["\(pair)Front"] = "\(label) Front"
            names["\(pair)Back"] = "\(label) Back"
        }

        var positions = survey.positions
        // The cashier session doesn't record which way it walked, so the cashier is drawn beside
        // the walk from the entrance, as far to the side as the entrance is. Only the drawing guesses:
        // the walked length is measured.
        let cashierMeters = cashier.edges.first?.lengthMeters ?? 0
        if let origin = positions["1"], let turn = positions["turn1"], let entrance = positions["entrance"] {
            let offset = entrance - turn
            let along = max(cashierMeters * cashierMeters - simd_length_squared(offset), 0).squareRoot()
            positions["cashier"] = origin + offset + simd_normalize(turn - origin) * along
        }

        // A quarter turn counterclockwise, to match the Target app.
        let nodes = positions.keys.sorted().map { id in
            let p = positions[id]!
            return Node(id: id, name: names[id] ?? id, x: -p.y, y: p.x)
        }
        // Surveyed edges use the straight line between their fitted ends (`length(of:)`).
        let edges = survey.edges.map { Edge(from: $0.from, to: $0.to) }
            + [Edge(from: "1", to: "cashier", meters: cashierMeters)]

        // Sides were checked in the store, for walking each lane's nodes in the order listed.
        var stops: [String: [Visit]] = [
            // Straight ahead at node 1, the first stop of a trip.
            "G7": [.stop("1", scanning: .ahead)],
            // Whole lanes: the items can be anywhere along them.
            "G6": Visit.lane(["2", "3", "4"], scanning: .left),
            "G8": Visit.lane(["3", "6"], scanning: .left),
            "G9": Visit.lane(["3", "6"], scanning: .right),
            "G13": Visit.lane(["5", "6", "7"], scanning: .left),
            // The back wall, like G42. Arriving at node 4 from node 3 it's straight ahead, but the
            // lane is always walked from one of its ends.
            "G44": Visit.lane(["44End", "4", "5"], scanning: .left),
            // The back wall, from aisle 17 to aisle 25.
            "G42": Visit.lane(["16_17Back", "18_19Back", "20_21Back", "22_23Back", "24_25Back"], scanning: .left),
        ]
        // Walking front to back, the even aisle is on the left and the odd one on the right.
        for pair in aislePairs {
            let aisles = pair.split(separator: "_")
            let lane = ["\(pair)Front", "\(pair)Back"]
            stops["G\(aisles[0])"] = Visit.lane(lane, scanning: .left)
            stops["G\(aisles[1])"] = Visit.lane(lane, scanning: .right)
        }

        let scanNodes = Set(stops.values.joined().filter { $0.path.count == 1 }.map { $0.path[0] })
        let kinds = nodes.map { node in
            var node = node
            node.kind = switch node.id {
            case "entrance": .start
            case "cashier": .cashier
            case _ where scanNodes.contains(node.id): .scan
            default: .walkway
            }
            return node
        }
        return StoreMap(nodes: kinds, edges: edges, stops: stops, startId: "entrance", cashierId: "cashier")
    }

    /// The fitted survey of every Target session but the cashier's, before it's turned to match the
    /// Target app: aisle numbers grow along x, and y runs from the aisle fronts to the back wall.
    static func targetSurvey(loading load: (String) -> CalibrationFile?) -> Survey? {
        guard let full = load("target-full-walk"), let grocery = load("target-grocery"),
              let walk = load("target-store-walk") else { return nil }
        var survey = Survey()

        // The walkable graph.
        let fronts = aislePairs.map { "\($0)Front" }, backs = aislePairs.map { "\($0)Back" }
        survey.line(.x, ["7"] + fronts)
        survey.line(.x, ["44End", "4", "5"] + backs)
        for pair in aislePairs { survey.line(.y, ["\(pair)Front", "\(pair)Back"]) }
        // The grocery section: node 1 faces aisle 7 at its front, and cuts diagonally to 2 and 7.
        survey.line(.y, ["2", "3", "4"])
        survey.line(.y, ["7", "6", "5"])
        survey.line(.x, ["3", "6"])
        survey.corner("1", "2")
        survey.corner("1", "7")
        // The walk in from the entrance.
        survey.line(.x, ["entrance", "turn1"])
        survey.line(.y, ["turn1", "checkpoint1", "checkpoint2", "checkpoint3", "checkpoint4", "1"])

        // The checkpoints are two aisle gaps short of 26/27 and four past 14/15, so aisle 22/23.
        // "Testing" is 0.35 m from node 7 and "Test 3" is between aisles, so walks through them are
        // joined.
        survey.add(Survey.Session(name: "full-walk", file: full, nodes: [
            "N1": "1", "N2": "2", "N3": "3", "N4": "4", "N5": "44End", "N6": "5", "N7": "6", "N8": "7",
            "N9": "14_15Front", "N10": "14_15Back", "N13": "16_17Back", "N14": "16_17Front",
            "N11": "22_23Back", "N12": "22_23Front", "N16": "26_27Front", "N17": "26_27Back",
            "N19": "34_35Back", "N20": "34_35Front",
        ], via: ["N15", "N18"]))

        // Same start and nearly the same heading as the full walk. Its "Aisle 1" is aisle 14/15.
        // Its 9 (partway along aisle 13's lane) and 4 (on the way across aisles 8/9) are walked through.
        survey.add(Survey.Session(name: "grocery", file: grocery, nodes: [
            "N1": "1", "N10": "2", "N5": "3", "N6": "4", "N7": "44End", "N8": "5", "N3": "6", "N2": "7",
            "N11": "14_15Front", "N12": "14_15Back",
        ], via: ["N9", "N4"]))

        // Its aisle rows run along its z, so it's turned a quarter turn clockwise. Its "G13" is node 5
        // (the back of aisle 13's lane). Its loop back through the grocery section is left out: the
        // other sessions map that better.
        survey.add(Survey.Session(name: "store-walk", file: walk, quarterTurns: -1, nodes: [
            "N1": "entrance", "N2": "turn1", "N3": "checkpoint1", "N4": "checkpoint2",
            "N5": "checkpoint3", "N6": "checkpoint4", "N7": "1",
            "N8": "14_15Front", "N9": "16_17Front", "N10": "18_19Front", "N11": "22_23Front",
            "N12": "24_25Front", "N13": "26_27Front", "N14": "28_29Front", "N15": "30_31Front",
            "N16": "32_33Front", "N17": "34_35Front", "N18": "34_35Back", "N19": "30_31Back",
            "N20": "28_29Back", "N21": "26_27Back", "N22": "24_25Back", "N23": "22_23Back",
            "N24": "20_21Back", "N25": "18_19Back", "N26": "16_17Back", "N27": "14_15Back", "N28": "5",
        ]))

        survey.fit(anchor: "1")
        return survey
    }
}

// MARK: - Fitting calibration sessions together

/// Fits calibration sessions into one map.
///
/// Every walk in a session (each edge's first walk, and every walk back along one) measures how
/// far, and which way, the phone moved between two nodes. That's measured straight from where the
/// walk began to where it ended, not along the path: turning on the spot at the start of an aisle
/// adds walked meters but no distance, and `RouteNavigator` measures progress the same straight way.
/// A session's positions drift over minutes, but one walk barely does, so where nodes were marked
/// is ignored and only these measurements count.
///
/// The store's aisles and walkways are straight and meet at right angles, so each edge lies along x
/// or y (`line`), and a walk counts only along its axis. A least-squares fit then places every
/// node: where walks disagree, it lands between them, trusting shorter walks more. A walk that
/// disagrees with the rest by more than `tolerance` is left out (`rejected`), worst first, as long
/// as other walks still cover that stretch.
struct Survey {
    enum Axis {
        case x, y
    }

    struct Measurement {
        let from: String
        let to: String
        /// Map meters from `from` to `to`.
        let delta: SIMD2<Double>
        /// The session and walk it came from ("full-walk E12"), for reading `rejected`.
        let source: String
    }

    /// A calibration session and how it sits on the map.
    struct Session {
        /// For `Measurement.source`.
        let name: String
        let file: CalibrationFile
        /// Counterclockwise quarter turns from the session's frame to the map's, on top of the small
        /// turn that squares its walks up with the grid.
        var quarterTurns = 0
        /// Session node → map node. Walks to other session nodes are left out, except through `via`.
        let nodes: [String: String]
        /// Session nodes that are only walked through: every walk in and walk out is joined into
        /// one walk between the nodes on either side.
        var via: Set<String> = []
    }

    /// A walk can be this far off the fit before it's left out: 0.75 m, or 8% of a long walk.
    static func tolerance(_ m: Measurement) -> Double { max(0.75, 0.08 * simd_length(m.delta)) }

    /// How much more keeping edges straight counts than any walk.
    static let straightness = 100.0

    /// The walkable graph. `axis` is nil for an edge that doesn't run along the grid.
    private(set) var edges: [(from: String, to: String, axis: Axis?)] = []
    private(set) var measurements: [Measurement] = []
    /// Measurements left out of the fit.
    private(set) var rejected: [Measurement] = []
    /// Where `fit` put each node.
    private(set) var positions: [String: SIMD2<Double>] = [:]

    /// A straight aisle or walkway along `axis`, with an edge between each consecutive pair of nodes.
    mutating func line(_ axis: Axis, _ ids: [String]) {
        for (a, b) in zip(ids, ids.dropFirst()) { edges.append((a, b, axis)) }
    }

    /// An edge that doesn't run along the grid.
    mutating func corner(_ a: String, _ b: String) {
        edges.append((a, b, nil))
    }

    mutating func add(_ session: Session) {
        let file = session.file
        typealias Walk = (from: String, to: String, delta: SIMD2<Double>, source: String)
        // Files point z backward; the map points y forward.
        func delta(_ points: [[Double]]) -> SIMD2<Double>? {
            guard let a = points.first, let b = points.last, a.count == 2, b.count == 2 else { return nil }
            return SIMD2(b[0] - a[0], a[1] - b[1])
        }
        var walks: [Walk] = []
        for path in file.paths {
            guard let edge = file.edges.first(where: { $0.id == path.edge }), let d = delta(path.points) else { continue }
            walks.append((edge.from, edge.to, d, edge.id))
        }
        // A walk that closed a loop is saved as both an edge's path and a return: counted once.
        let returns = file.edges.flatMap(\.returns)
        for path in file.returnPaths where !file.paths.contains(where: { $0.points == path.points }) {
            guard let back = returns.first(where: { $0.id == path.returnId }), let d = delta(path.points) else { continue }
            walks.append((back.from, back.to, d, back.id))
        }

        let angle = Self.squaringAngle(walks.map(\.delta)) + Double(session.quarterTurns) * .pi / 2
        walks = walks.map { ($0.from, $0.to, Self.rotate($0.delta, by: angle), $0.source) }

        var joined = walks.filter { !session.via.contains($0.from) && !session.via.contains($0.to) }
        for via in session.via.sorted() {
            // Every walk in or out, pointed away from the node walked through.
            let out: [Walk] = walks.compactMap { walk -> Walk? in
                if walk.from == via { return walk }
                if walk.to == via { return (walk.to, walk.from, -walk.delta, walk.source) }
                return nil
            }
            for i in out.indices {
                for j in out.indices where i < j && out[i].to != out[j].to {
                    joined.append((out[i].to, out[j].to, out[j].delta - out[i].delta, "\(out[i].source)+\(out[j].source)"))
                }
            }
        }
        for walk in joined {
            guard let a = session.nodes[walk.from], let b = session.nodes[walk.to], a != b else { continue }
            measurements.append(Measurement(from: a, to: b, delta: walk.delta, source: "\(session.name) \(walk.source)"))
        }
    }

    /// Places every node, with `anchor` at (0, 0), leaving out walks that don't fit (see `Survey`).
    mutating func fit(anchor: String) {
        var used = measurements.indices.filter { !axes(of: measurements[$0]).isEmpty }
        rejected = measurements.indices.filter { !used.contains($0) }.map { measurements[$0] }
        guard let first = solve(used, anchor: anchor) else {
            assertionFailure("Some node's position isn't pinned down by any walk")
            return
        }
        positions = first
        var needed: Set<Int> = []
        while true {
            func pairs(_ i: Int) -> Set<String> { [measurements[i].from, measurements[i].to] }
            let droppable = used.filter { i in
                !needed.contains(i)
                    && (!edges.contains { pairs(i) == [$0.from, $0.to] } || used.contains { $0 != i && pairs($0) == pairs(i) })
            }
            func badness(_ i: Int) -> Double { (misfit(measurements[i]) ?? 0) / Self.tolerance(measurements[i]) }
            guard let worst = droppable.max(by: { badness($0) < badness($1) }), badness(worst) > 1 else { return }
            let rest = used.filter { $0 != worst }
            if let refit = solve(rest, anchor: anchor) {
                used = rest
                positions = refit
                rejected.append(measurements[worst])
            } else {
                needed.insert(worst)
            }
        }
    }

    /// Meters between what a walk measured and the fitted map, along the axes it counts on.
    func misfit(_ m: Measurement) -> Double? {
        guard let a = positions[m.from], let b = positions[m.to] else { return nil }
        return axes(of: m).map { abs(Self.component(b - a, $0) - Self.component(m.delta, $0)) }.max()
    }

    /// The axes a walk counts along: its edge's, or, for a walk past other nodes, the grid axis it
    /// ran along. None for one that ran across the grid past other nodes.
    func axes(of m: Measurement) -> [Axis] {
        if let edge = edges.first(where: { Set([$0.from, $0.to]) == [m.from, m.to] }) {
            return edge.axis.map { [$0] } ?? [.x, .y]
        }
        let degrees = atan2(abs(m.delta.y), abs(m.delta.x)) * 180 / .pi
        return degrees <= 20 ? [.x] : degrees >= 70 ? [.y] : []
    }

    /// Least squares, one axis at a time: each walk says how far apart its ends are along its axis,
    /// weighted by 1 / its length (errors build up as you walk), and each straight edge says its ends
    /// line up across it. Nil if some node isn't pinned down.
    private func solve(_ used: [Int], anchor: String) -> [String: SIMD2<Double>]? {
        let ids = Array(Set(edges.flatMap { [$0.from, $0.to] })).sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        guard let pinned = index[anchor] else { return nil }
        var rows: [Axis: [Row]] = [.x: [], .y: []]
        for edge in edges {
            guard let axis = edge.axis, let a = index[edge.from], let b = index[edge.to] else { continue }
            rows[axis == .x ? .y : .x]!.append(Row(from: a, to: b, meters: 0, weight: Self.straightness))
        }
        for i in used {
            let m = measurements[i]
            guard let a = index[m.from], let b = index[m.to] else { continue }
            let weight = 1 / max(simd_length(m.delta), 2)
            for axis in axes(of: m) {
                rows[axis]!.append(Row(from: a, to: b, meters: Self.component(m.delta, axis), weight: weight))
            }
        }
        guard let xs = Self.leastSquares(count: ids.count, rows[.x]!, anchor: pinned),
              let ys = Self.leastSquares(count: ids.count, rows[.y]!, anchor: pinned) else { return nil }
        return Dictionary(uniqueKeysWithValues: ids.indices.map { (ids[$0], SIMD2(xs[$0], ys[$0])) })
    }

    /// Node `to` sits `meters` past node `from`.
    private struct Row {
        let from: Int
        let to: Int
        let meters: Double
        let weight: Double
    }

    /// Solves the weighted rows for `count` unknowns, with `anchor` at 0, by Gaussian elimination on
    /// the normal equations; the map is a few dozen nodes.
    private static func leastSquares(count n: Int, _ rows: [Row], anchor: Int) -> [Double]? {
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        a[anchor][anchor] = 1e6
        for row in rows {
            a[row.from][row.from] += row.weight
            a[row.to][row.to] += row.weight
            a[row.from][row.to] -= row.weight
            a[row.to][row.from] -= row.weight
            b[row.to] += row.weight * row.meters
            b[row.from] -= row.weight * row.meters
        }
        for column in 0..<n {
            let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard abs(a[pivot][column]) > 1e-9 else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in column + 1..<n where a[row][column] != 0 {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var solved = [Double](repeating: 0, count: n)
        for row in (0..<n).reversed() {
            // Two steps: as one expression, Swift can't type-check it in time (Xcode 26.3).
            let known = (row + 1..<n).reduce(0.0) { $0 + a[row][$1] * solved[$1] }
            solved[row] = (b[row] - known) / a[row][row]
        }
        return solved
    }

    /// The small turn that best lines walks up with the grid: each walk's direction times four,
    /// so directions a quarter turn apart agree, averaged by length.
    private static func squaringAngle(_ deltas: [SIMD2<Double>]) -> Double {
        var sine = 0.0, cosine = 0.0
        for d in deltas where simd_length(d) >= 2 {
            let angle = 4 * atan2(d.y, d.x)
            sine += simd_length(d) * sin(angle)
            cosine += simd_length(d) * cos(angle)
        }
        return -atan2(sine, cosine) / 4
    }

    private static func rotate(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        SIMD2(v.x * cos(angle) - v.y * sin(angle), v.x * sin(angle) + v.y * cos(angle))
    }

    private static func component(_ v: SIMD2<Double>, _ axis: Axis) -> Double {
        axis == .x ? v.x : v.y
    }
}
