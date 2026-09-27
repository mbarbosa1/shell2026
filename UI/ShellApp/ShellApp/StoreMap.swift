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
    /// Map frame: the grocery session's, with y pointing to the back of the store. Grocery lanes
    /// run up the map, and the aisle numbers grow to the right.
    static let target = target(loading: CalibrationFile.bundled)

    /// Aisles only walked at their ends get a lane this long (measured on aisles 14/15 and 34/35).
    static let aisleMeters = 12.7

    static func target(loading load: (String) -> CalibrationFile?) -> StoreMap {
        guard let grocery = load("target-grocery"),
              let walk = load("target-store-walk"),
              let cashier = load("target-cashier") else {
            assertionFailure("The Target calibration files are missing from the app bundle")
            return StoreMap(nodes: [], edges: [], stops: [:], startId: "entrance", cashierId: "cashier")
        }
        var map = Assembly()

        // The grocery section, as calibrated. Its "Start" is node 1, and "Aisle 1" is aisle 14/15.
        map.add(grocery, placement: Placement(), nodes: [
            "N1": ("1", "Node 1"), "N2": ("2", "Node 2"), "N3": ("3", "Node 3"), "N4": ("4", "Node 4"),
            "N5": ("5", "Node 5"), "N6": ("6", "Node 6"), "N7": ("7", "Node 7"), "N8": ("8", "Node 8"),
            "N9": ("9", "Node 9"), "N10": ("10", "Node 10"),
            "N11": ("14_15Front", "14/15 Front"), "N12": ("14_15Back", "14/15 Back"),
        ])

        // The store walk ran the aisle rows along x instead of y, so it's turned a quarter turn
        // clockwise. Its two parts are pinned separately, at node 1 and at the front of 14/15, so
        // the ~80 m walk from the entrance doesn't carry its drift into the aisles.
        map.add(walk, placement: map.placement(of: walk, turning: -.pi / 2, pinning: "N7", to: "1"), nodes: [
            "N1": ("entrance", "Entrance"), "N2": ("turn1", "Turn 1"),
            "N3": ("checkpoint1", "Checkpoint 1"), "N4": ("checkpoint2", "Checkpoint 2"),
            "N5": ("checkpoint3", "Checkpoint 3"), "N6": ("checkpoint4", "Checkpoint 4"),
            "N7": ("1", "Node 1"),
        ])
        // Skipped from this walk: its grocery nodes (the grocery session maps them better) and its
        // node 1 → 14/15 edge (4.3 m, where the grocery session walked 7.0 m through node 2).
        map.add(walk, placement: map.placement(of: walk, turning: -.pi / 2, pinning: "N8", to: "14_15Front"), nodes: [
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

        // One straight walk from node 1. The session doesn't record which way that is on the map,
        // so the cashier is drawn toward the entrance. Its length is measured; only the drawing guesses.
        map.add(cashier, placement: map.placement(of: cashier, aiming: ("N1", "N2"), from: "1", toward: "entrance"), nodes: [
            "N1": ("1", "Node 1"), "N2": ("cashier", "Cashier"),
        ])

        // Aisles walked only at their ends.
        for pair in ["16_17", "18_19", "22_23", "24_25", "26_27", "28_29", "30_31"] {
            map.edges.append(Edge(from: "\(pair)Front", to: "\(pair)Back", meters: aisleMeters))
        }

        let stops: [String: [Visit]] = [
            "G7": [.stop("1")],
            "G8": [.stop("4")],
            // TODO: G9 and G10 are assumed (G9 across from G8, G10 on aisle 13's lane). Check in store.
            "G9": [.stop("4")],
            "G10": [.stop("9")],
            // Whole lanes: the items can be anywhere along them.
            "G13": Visit.lane(["2", "3", "9", "8"]),
            "G6": Visit.lane(["10", "5", "6"]),
            "G44": Visit.lane(["6", "7"]),
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

    /// Pins the file's first node of `aiming` on map node `mapNode`, turned so the second one lies
    /// in the direction of map node `target`.
    func placement(of file: CalibrationFile, aiming: (String, String),
                   from mapNode: String, toward target: String) -> Placement {
        guard let a = file.node(aiming.0), let b = file.node(aiming.1),
              let from = position(of: mapNode), let to = position(of: target) else { return Placement() }
        let base = Placement()
        let (ax, ay) = base(a.position), (bx, by) = base(b.position)
        let angle = atan2(to.y - from.y, to.x - from.x) - atan2(by - ay, bx - ax)
        return placement(of: file, turning: angle, pinning: aiming.0, to: mapNode)
    }
}
