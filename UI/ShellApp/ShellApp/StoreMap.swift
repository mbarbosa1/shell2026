import Foundation

/// The store as a walkable graph: named nodes at (x, y) positions in meters, edges between the
/// ones you can walk straight between, and where to scan for each store location ("G44").
///
/// Built from calibration sessions (see `CalibrationFile`). Edge lengths are the walked lengths,
/// which is all route planning uses. Positions only draw the map, so a few meters of drift in them
/// doesn't change any route.
struct StoreMap {
    enum Kind {
        case start, cashier, walkway, scan
    }

    /// Which way the camera looks to scan a shelf, in map directions.
    enum Side: String {
        case up, down, left, right
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
        static func lane(_ nodes: [String], scanning side: Side? = nil) -> [Visit] {
            [Visit(path: nodes, side: side), Visit(path: nodes.reversed(), side: side)]
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
    /// Target Waterford Lakes, from three calibration sessions on Sep 26, 2026 (in Calibration/):
    /// - `target-grocery` (calibration_2026-09-26T23-56-11Z): the grocery section, node by node.
    /// - `target-store-walk` (calibration_2026-09-26T20-14-37Z): the entrance to node 1, and the
    ///   front and back ends of aisles 14/15 to 34/35.
    /// - `target-cashier` (calibration_2026-09-27T00-05-10Z): node 1 to the cashier.
    ///
    /// Node 1 is the only way into the grocery section, so every route starts with the same walk
    /// from the entrance and ends with the same walk to the cashier.
    ///
    /// Drawn like the Target app's map: the back wall on the left, aisle numbers growing up the
    /// map, the entrance at the bottom right. Positions are straightened (see `straighten`), so the
    /// drawing shows the store's straight aisles instead of the sensor's drift.
    static let target = target(loading: CalibrationFile.bundled)

    /// Length of every aisle from 14/15 up: measured on its own, between the store walks' 13.7 m
    /// (16/17) and 12.0 m (34/35).
    static let aisleMeters = 12.7

    /// The ends of the aisles from 13 up, as (aisle pairs from aisle 13, node). These aisles are
    /// evenly spaced in the store, so the walked gaps between them are averaged (see `spaceEvenly`).
    static let aisleRows: [[(step: Int, id: String)]] = [
        [(0, "2"), (1, "14_15Front"), (2, "16_17Front"), (3, "18_19Front"), (4, "20_21Front"),
         (5, "22_23Front"), (6, "24_25Front"), (7, "26_27Front"), (8, "28_29Front"), (9, "30_31Front"),
         (10, "32_33Front"), (11, "34_35Front")],
        [(0, "8"), (1, "14_15Back"), (2, "16_17Back"), (3, "18_19Back"), (4, "20_21Back"),
         (5, "22_23Back"), (6, "24_25Back"), (7, "26_27Back"), (8, "28_29Back"), (9, "30_31Back"),
         (11, "34_35Back")],
    ]

    static func target(loading load: (String) -> CalibrationFile?) -> StoreMap {
        guard let grocery = load("target-grocery"),
              let walk = load("target-store-walk"),
              let cashier = load("target-cashier") else {
            assertionFailure("The Target calibration files are missing from the app bundle")
            return StoreMap(nodes: [], edges: [], stops: [:], startId: "entrance", cashierId: "cashier")
        }
        var map = Assembly()

        // The grocery section, as calibrated. Its "Start" is node 1, and "Aisle 1" is aisle 16/17.
        map.add(grocery, placement: Placement(), nodes: [
            "N1": ("1", "Node 1"), "N2": ("2", "Node 2"), "N3": ("3", "Node 3"), "N4": ("4", "Node 4"),
            "N5": ("5", "Node 5"), "N6": ("6", "Node 6"), "N7": ("7", "Node 7"), "N8": ("8", "Node 8"),
            "N9": ("9", "Node 9"), "N10": ("10", "Node 10"),
            "N11": ("16_17Front", "16/17 Front"), "N12": ("16_17Back", "16/17 Back"),
        ])

        // The store walk ran the aisle rows along x instead of y, so it's turned a quarter turn
        // clockwise. Its two parts are pinned separately, at node 1 and at the front of 16/17, so
        // the ~80 m walk from the entrance doesn't carry its drift into the aisles.
        map.add(walk, placement: map.placement(of: walk, turning: -.pi / 2, pinning: "N7", to: "1"), nodes: [
            "N1": ("entrance", "Entrance"), "N2": ("turn1", "Turn 1"),
            "N3": ("checkpoint1", "Checkpoint 1"), "N4": ("checkpoint2", "Checkpoint 2"),
            "N5": ("checkpoint3", "Checkpoint 3"), "N6": ("checkpoint4", "Checkpoint 4"),
            "N7": ("1", "Node 1"),
        ])
        // Its "G13" is node 8 (the back of aisle 13's lane). Its other grocery nodes are skipped:
        // the grocery session maps them better.
        map.add(walk, placement: map.placement(of: walk, turning: -.pi / 2, pinning: "N9", to: "16_17Front"), nodes: [
            "N7": ("1", "Node 1"), "N28": ("8", "Node 8"),
            "N8": ("14_15Front", "14/15 Front"), "N9": ("16_17Front", "16/17 Front"),
            "N10": ("18_19Front", "18/19 Front"), "N11": ("22_23Front", "22/23 Front"),
            "N12": ("24_25Front", "24/25 Front"), "N13": ("26_27Front", "26/27 Front"),
            "N14": ("28_29Front", "28/29 Front"), "N15": ("30_31Front", "30/31 Front"),
            "N16": ("32_33Front", "32/33 Front"), "N17": ("34_35Front", "34/35 Front"),
            "N18": ("34_35Back", "34/35 Back"), "N19": ("30_31Back", "30/31 Back"),
            "N20": ("28_29Back", "28/29 Back"), "N21": ("26_27Back", "26/27 Back"),
            "N22": ("24_25Back", "24/25 Back"), "N23": ("22_23Back", "22/23 Back"),
            "N24": ("20_21Back", "20/21 Back"), "N25": ("18_19Back", "18/19 Back"),
            "N26": ("16_17Back", "16/17 Back"), "N27": ("14_15Back", "14/15 Back"),
        ])

        // One straight walk from node 1, placed after straightening (below).
        map.add(cashier, placement: Placement(), nodes: [
            "N1": ("1", "Node 1"), "N2": ("cashier", "Cashier"),
        ])

        // Not walked: the front of 20/21, across from its back.
        map.addNode("20_21Front", name: "20/21 Front", between: ("18_19Front", "22_23Front"))

        // Even aisle spacing. Node 1 reached the aisle rows past node 2, so its shortcut to 14/15
        // goes too; the grocery session's 2 → 16/17 and 8 → 16/17 pass 14/15 and are replaced too.
        map.edges.removeAll { Set([$0.from, $0.to]) == ["1", "14_15Front"] }
        map.spaceEvenly(rows: aisleRows)

        // Every aisle the same length, walked or not.
        let pairs = ["14_15", "16_17", "18_19", "20_21", "22_23", "24_25", "26_27", "28_29", "30_31", "34_35"]
        map.edges.removeAll { edge in pairs.contains { Set([edge.from, edge.to]) == ["\($0)Front", "\($0)Back"] } }
        for pair in pairs {
            map.edges.append(Edge(from: "\(pair)Front", to: "\(pair)Back", meters: aisleMeters))
        }

        map.straighten(pinning: "1", except: ["cashier"])
        // The cashier session doesn't record which way it walked, so the cashier is drawn beside
        // the walk from the entrance, as far to the side as the entrance is. Only the drawing guesses:
        // the walked length is measured.
        map.place("cashier", from: "1", meters: cashier.edges.first?.lengthMeters ?? 0,
                  alongside: ("turn1", "entrance"))
        // A quarter turn counterclockwise, to match the Target app.
        map.nodes = map.nodes.map { StoreMap.Node(id: $0.id, name: $0.name, x: -$0.y, y: $0.x) }

        let stops: [String: [Visit]] = [
            "G7": [.stop("1")],
            "G8": [.stop("4")],
            // TODO: G9 is assumed to be across from G8. Check in store.
            "G9": [.stop("4")],
            // Whole lanes: the items can be anywhere along them.
            "G13": Visit.lane(["2", "3", "9", "8"]),
            "G6": Visit.lane(["10", "5", "6"]),
            "G44": Visit.lane(["6", "7"]),
            // The back wall, from aisle 17 to aisle 25.
            "G42": Visit.lane(["16_17Back", "18_19Back", "20_21Back", "22_23Back", "24_25Back"], scanning: .left),
            "G14": Visit.lane(["14_15Front", "14_15Back"]),
            "G15": Visit.lane(["14_15Front", "14_15Back"]),
            "G16": Visit.lane(["16_17Front", "16_17Back"]),
            "G17": Visit.lane(["16_17Front", "16_17Back"]),
            "G26": Visit.lane(["26_27Front", "26_27Back"]),
            "G27": Visit.lane(["26_27Front", "26_27Back"]),
            "G34": Visit.lane(["34_35Front", "34_35Back"]),
            "G35": Visit.lane(["34_35Front", "34_35Back"]),
        ]

        let scanNodes = Set(stops.values.joined().filter { $0.path.count == 1 }.map { $0.path[0] })
        let nodes = map.nodes.map { node in
            var node = node
            node.kind = switch node.id {
            case "entrance": .start
            case "cashier": .cashier
            case _ where scanNodes.contains(node.id): .scan
            default: .walkway
            }
            return node
        }
        return StoreMap(nodes: nodes, edges: map.edges, stops: stops, startId: "entrance", cashierId: "cashier")
    }
}

// MARK: - Assembling calibration files

/// Where a calibration file's frame sits on the map: a turn, then a move.
private struct Placement {
    /// Radians, counterclockwise.
    var angle = 0.0
    var dx = 0.0
    var dy = 0.0

    /// A file's [x, z] on the map. Files point z backward (down, seen from above), the map points y up.
    func callAsFunction(_ position: [Double]) -> (x: Double, y: Double) {
        let x = position[0], y = -position[1]
        return (x * cos(angle) - y * sin(angle) + dx, x * sin(angle) + y * cos(angle) + dy)
    }
}

/// Collects nodes and edges from several calibration files into one map.
private struct Assembly {
    var nodes: [StoreMap.Node] = []
    var edges: [StoreMap.Edge] = []

    func position(of id: String) -> (x: Double, y: Double)? {
        nodes.first { $0.id == id }.map { ($0.x, $0.y) }
    }

    /// Adds the file's nodes listed in `ids` (file node id → map id and name) and the edges between
    /// them. A node whose map id is already on the map joins it and keeps the existing position.
    mutating func add(_ file: CalibrationFile, placement: Placement,
                      nodes ids: [String: (id: String, name: String)]) {
        for node in file.nodes {
            guard let mapped = ids[node.id], position(of: mapped.id) == nil else { continue }
            let p = placement(node.position)
            nodes.append(StoreMap.Node(id: mapped.id, name: mapped.name, x: p.x, y: p.y))
        }
        for edge in file.edges {
            guard let from = ids[edge.from]?.id, let to = ids[edge.to]?.id else { continue }
            edges.append(StoreMap.Edge(from: from, to: to, meters: edge.lengthMeters))
        }
    }

    /// Turns the file by `angle`, then moves it so its node `fileNode` lands on map node `mapNode`.
    func placement(of file: CalibrationFile, turning angle: Double,
                   pinning fileNode: String, to mapNode: String) -> Placement {
        var placement = Placement(angle: angle)
        guard let from = file.node(fileNode), let to = position(of: mapNode) else { return placement }
        let turned = placement(from.position)
        placement.dx = to.x - turned.x
        placement.dy = to.y - turned.y
        return placement
    }

    /// Adds a node halfway between two others, to be placed properly by `straighten`.
    mutating func addNode(_ id: String, name: String, between ends: (String, String)) {
        guard let a = position(of: ends.0), let b = position(of: ends.1) else { return }
        nodes.append(StoreMap.Node(id: id, name: name, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    }

    /// Evenly spaced rows of aisle ends. `rows` lists each row's nodes in order with how many aisle
    /// pairs along the row they are. The average walked meters per pair, over every row edge from
    /// step 1 up, replaces all edges within a row: consecutive nodes get steps × that average.
    mutating func spaceEvenly(rows: [[(step: Int, id: String)]]) {
        var meters = 0.0, steps = 0
        var rowOf: [String: Int] = [:], stepOf: [String: Int] = [:]
        for (row, nodes) in rows.enumerated() {
            for node in nodes { rowOf[node.id] = row; stepOf[node.id] = node.step }
        }
        for edge in edges {
            guard let row = rowOf[edge.from], rowOf[edge.to] == row, let a = stepOf[edge.from],
                  let b = stepOf[edge.to], min(a, b) >= 1, let length = edge.meters else { continue }
            meters += length
            steps += abs(a - b)
        }
        guard steps > 0 else { return }
        let perStep = meters / Double(steps)
        edges.removeAll { edge in rowOf[edge.from] != nil && rowOf[edge.from] == rowOf[edge.to] }
        for row in rows {
            for (a, b) in zip(row, row.dropFirst()) {
                edges.append(StoreMap.Edge(from: a.id, to: b.id, meters: Double(b.step - a.step) * perStep))
            }
        }
    }

    /// Lines positions up the way the store is built. Aisles and walkways are straight and meet at
    /// right angles, so every edge is made exactly horizontal or vertical, whichever it's closer to,
    /// at its walked length. Where loops disagree on lengths, a least-squares fit spreads the
    /// difference, with straightness weighted 100× over length so rows stretch instead of aisles
    /// bending. Only positions move; edge lengths are unchanged.
    mutating func straighten(pinning anchor: String, except skipped: Set<String>) {
        struct Rule {
            /// The other node, and where this one should be relative to it, with weights.
            let other: Int
            let dx, dy, weightX, weightY: Double
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var rules = [[Rule]](repeating: [], count: nodes.count)
        for edge in edges where !skipped.contains(edge.from) && !skipped.contains(edge.to) {
            guard let a = index[edge.from], let b = index[edge.to], let meters = edge.meters else { continue }
            let dx = nodes[b].x - nodes[a].x, dy = nodes[b].y - nodes[a].y
            let (x, y, weightX, weightY): (Double, Double, Double, Double) = abs(dx) >= abs(dy)
                ? (dx < 0 ? -meters : meters, 0, 1, 100)
                : (0, dy < 0 ? -meters : meters, 100, 1)
            rules[b].append(Rule(other: a, dx: x, dy: y, weightX: weightX, weightY: weightY))
            rules[a].append(Rule(other: b, dx: -x, dy: -y, weightX: weightX, weightY: weightY))
        }
        // Least squares, one axis at a time: each node's row says it sits where its edges put it,
        // weighted. The anchor and nodes with no edges stay put. Solved by Gaussian elimination;
        // the map is a few dozen nodes.
        func solve(_ current: [Double], offset: (Rule) -> Double, weight: (Rule) -> Double) -> [Double] {
            let n = nodes.count
            var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var b = current
            for i in 0..<n {
                if nodes[i].id == anchor || rules[i].isEmpty {
                    a[i][i] = 1
                    continue
                }
                b[i] = 0
                for rule in rules[i] {
                    a[i][i] += weight(rule)
                    a[i][rule.other] -= weight(rule)
                    b[i] += weight(rule) * offset(rule)
                }
            }
            for column in 0..<n {
                let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
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
                solved[row] = (b[row] - (row + 1..<n).reduce(0) { $0 + a[row][$1] * solved[$1] }) / a[row][row]
            }
            return solved
        }
        let xs = solve(nodes.map(\.x), offset: \.dx, weight: \.weightX)
        let ys = solve(nodes.map(\.y), offset: \.dy, weight: \.weightY)
        nodes = nodes.indices.map { StoreMap.Node(id: nodes[$0].id, name: nodes[$0].name, x: xs[$0], y: ys[$0]) }
    }

    /// Puts `id` `meters` from `origin`: offset to the side as far as `side.1` is from `side.0`, and
    /// the rest of the way in the direction from `origin` to `side.0`.
    mutating func place(_ id: String, from origin: String, meters: Double, alongside side: (String, String)) {
        guard let node = nodes.firstIndex(where: { $0.id == id }), let o = position(of: origin),
              let a = position(of: side.0), let b = position(of: side.1) else { return }
        let length = hypot(a.x - o.x, a.y - o.y)
        let offset = (x: b.x - a.x, y: b.y - a.y)
        let along = (max(meters * meters - offset.x * offset.x - offset.y * offset.y, 0)).squareRoot()
        nodes[node] = StoreMap.Node(id: id, name: nodes[node].name,
                                    x: o.x + offset.x + (a.x - o.x) / length * along,
                                    y: o.y + offset.y + (a.y - o.y) / length * along)
    }
}
