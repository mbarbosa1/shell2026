import Foundation

/// The on-disk format of a calibration session: what Export shares and what
/// a later navigation step reads. Kept separate from the in-memory models
/// (Models.swift) so the file can be shaped for people reading it:
/// - short IDs (N1, E1, R1) instead of UUIDs, and a readable label per edge
/// - a summary first; bulky path points in their own sections at the end
/// - positions rounded to the centimeter, units in the key names
/// - fields in a fixed reading order, every point as [x, z] on one line
struct SessionFile: Codable {
    var format = "shell-calibration-v2"
    var store: String
    var savedAt: Date
    var coordinates = "Meters, seen from above. Points are [x, z]: x = right, z = backward, relative to where the phone was when calibration opened. headingDegrees: 0 = the direction faced at that moment, positive = turned left."
    /// Distance from the camera lens back to the recorded pivot (cart rear
    /// axle). Every position in this file was recorded with this value.
    var pivotOffsetMeters: Double?
    var summary: Summary
    var start: Start?
    var nodes: [Node]
    var edges: [Edge]
    var restarts: [Restart]
    /// The recorded walking path of each edge (first traversal).
    var paths: [Path]
    /// The path walked on each return, kept for reviewing drift only.
    var returnPaths: [ReturnPath]

    struct Summary: Codable {
        var nodes: Int
        var edges: Int
        var totalWalkedMeters: Double
        var returns: Int
        var flaggedReturns: Int
        var restarts: Int
        var blockedRestarts: Int
    }

    /// Where the first node (the entrance) was marked and which way the
    /// phone faced there.
    struct Start: Codable {
        var node: String?
        var position: [Double]
        var headingDegrees: Double
    }

    struct Node: Codable {
        var id: String
        var name: String
        var position: [Double]
    }

    struct Edge: Codable {
        var id: String
        var label: String
        var from: String
        var to: String
        var lengthMeters: Double
        var bidirectional: Bool
        var returns: [Return]
    }

    /// One "Return to Existing" along this edge: how far the tracked
    /// position was from the node's recorded position on arrival.
    struct Return: Codable {
        var id: String
        var from: String
        var to: String
        var time: Date
        var offByMeters: Double
        var flagged: Bool
        var arrivedAt: [Double]
    }

    struct Restart: Codable {
        var atNode: String
        var time: Date
        var offByMeters: Double
        var blocked: Bool
        var measuredAt: [Double]
    }

    struct Path: Codable {
        var edge: String
        var points: [[Double]]
    }

    struct ReturnPath: Codable {
        var `return`: String
        var points: [[Double]]
    }
}

// MARK: - Conversion

extension SessionFile {
    init(_ session: CalibrationSessionData, savedAt: Date) {
        var shortNodeId: [String: String] = [:]
        for (i, node) in session.nodes.enumerated() { shortNodeId[node.id] = "N\(i + 1)" }
        // A reference to a node that no longer exists (e.g. an undone node
        // named by an old restart record) keeps its original ID rather than
        // silently pointing at whichever node reuses its number.
        func ref(_ id: String) -> String { shortNodeId[id] ?? id }
        let names = Dictionary(uniqueKeysWithValues: session.nodes.map { ($0.id, $0.name) })

        var edges: [Edge] = []
        var paths: [Path] = []
        var returnPaths: [ReturnPath] = []
        var returnCount = 0
        for (i, edge) in session.edges.enumerated() {
            let edgeId = "E\(i + 1)"
            var returns: [Return] = []
            for obs in edge.visitObservations {
                returnCount += 1
                let returnId = "R\(returnCount)"
                returns.append(Return(id: returnId, from: ref(obs.fromNodeId), to: ref(obs.toNodeId),
                                      time: obs.timestamp, offByMeters: cm(obs.discrepancy),
                                      flagged: obs.flagged, arrivedAt: point(obs.arrivalPosition)))
                returnPaths.append(ReturnPath(return: returnId, points: obs.diagnosticTrail.map(point)))
            }
            let label = "\(names[edge.fromNodeId] ?? ref(edge.fromNodeId)) → \(names[edge.toNodeId] ?? ref(edge.toNodeId))"
            edges.append(Edge(id: edgeId, label: label, from: ref(edge.fromNodeId), to: ref(edge.toNodeId),
                              lengthMeters: cm(edge.breadcrumbs.pathLength), bidirectional: edge.bidirectional,
                              returns: returns))
            paths.append(Path(edge: edgeId, points: edge.breadcrumbs.map(point)))
        }

        let observations = session.edges.flatMap(\.visitObservations)
        self.store = session.storeName
        self.savedAt = savedAt
        self.pivotOffsetMeters = session.pivotOffsetMeters.map(cm)
        self.summary = Summary(
            nodes: session.nodes.count,
            edges: session.edges.count,
            totalWalkedMeters: cm(session.edges.reduce(0) { $0 + $1.breadcrumbs.pathLength }),
            returns: observations.count,
            flaggedReturns: observations.filter(\.flagged).count,
            restarts: session.restartEvents.count,
            blockedRestarts: session.restartEvents.filter(\.blocked).count
        )
        self.start = session.startPose.map {
            Start(node: session.nodes.first.map { ref($0.id) },
                  position: point($0.position),
                  headingDegrees: (($0.headingDegrees * 10).rounded() / 10) + 0)
        }
        self.nodes = session.nodes.map { Node(id: ref($0.id), name: $0.name, position: point($0.position)) }
        self.edges = edges
        self.restarts = session.restartEvents.map {
            Restart(atNode: ref($0.nodeId), time: $0.timestamp, offByMeters: cm($0.discrepancy),
                    blocked: $0.blocked, measuredAt: point($0.measuredPosition))
        }
        self.paths = paths
        self.returnPaths = returnPaths
    }

    /// Rebuilds the in-memory model, for DISPLAY only (the map of a prior
    /// session). IDs become the short file IDs.
    func toSession() -> CalibrationSessionData {
        let pathByEdge = Dictionary(paths.map { ($0.edge, $0.points) }, uniquingKeysWith: { first, _ in first })
        let pathByReturn = Dictionary(returnPaths.map { ($0.return, $0.points) }, uniquingKeysWith: { first, _ in first })

        var session = CalibrationSessionData(storeName: store)
        session.pivotOffsetMeters = pivotOffsetMeters
        session.startPose = start.map { StartPose(position: point2D($0.position), headingDegrees: $0.headingDegrees) }
        session.nodes = nodes.map { NodeRecord(id: $0.id, name: $0.name, position: point2D($0.position)) }
        session.edges = edges.map { edge in
            var record = EdgeRecord(id: edge.id, fromNodeId: edge.from, toNodeId: edge.to,
                                    breadcrumbs: (pathByEdge[edge.id] ?? []).map(point2D),
                                    bidirectional: edge.bidirectional)
            record.visitObservations = edge.returns.map {
                VisitObservation(fromNodeId: $0.from, toNodeId: $0.to, arrivalPosition: point2D($0.arrivedAt),
                                 discrepancy: $0.offByMeters, timestamp: $0.time, flagged: $0.flagged,
                                 diagnosticTrail: (pathByReturn[$0.id] ?? []).map(point2D))
            }
            return record
        }
        session.restartEvents = restarts.map {
            RestartEvent(nodeId: $0.atNode, measuredPosition: point2D($0.measuredAt),
                         discrepancy: $0.offByMeters, timestamp: $0.time, blocked: $0.blocked)
        }
        return session
    }
}

// MARK: - Encoding / decoding

extension SessionFile {
    /// Written by hand rather than with JSONEncoder, which doesn't keep keys
    /// in any fixed order — here the summary always comes first and the
    /// bulky paths last. Keys must match the Codable property names so
    /// `decode` can read the file back (checked by a round trip).
    func encoded() -> Data {
        let dates = ISO8601DateFormatter()
        func pt(_ p: [Double]) -> JSON { .array(p.map(JSON.number)) }
        func points(_ ps: [[Double]]) -> JSON { .array(ps.map(pt)) }

        let root: JSON = .object([
            ("format", .string(format)),
            ("store", .string(store)),
            ("savedAt", .string(dates.string(from: savedAt))),
            ("coordinates", .string(coordinates)),
            ("pivotOffsetMeters", pivotOffsetMeters.map(JSON.number) ?? .null),
            ("summary", .object([
                ("nodes", .number(Double(summary.nodes))),
                ("edges", .number(Double(summary.edges))),
                ("totalWalkedMeters", .number(summary.totalWalkedMeters)),
                ("returns", .number(Double(summary.returns))),
                ("flaggedReturns", .number(Double(summary.flaggedReturns))),
                ("restarts", .number(Double(summary.restarts))),
                ("blockedRestarts", .number(Double(summary.blockedRestarts))),
            ])),
            ("start", start.map { start in
                .object([
                    ("node", start.node.map(JSON.string) ?? .null),
                    ("position", pt(start.position)),
                    ("headingDegrees", .number(start.headingDegrees)),
                ])
            } ?? .null),
            ("nodes", .array(nodes.map { node in
                .object([
                    ("id", .string(node.id)),
                    ("name", .string(node.name)),
                    ("position", pt(node.position)),
                ])
            })),
            ("edges", .array(edges.map { edge in
                .object([
                    ("id", .string(edge.id)),
                    ("label", .string(edge.label)),
                    ("from", .string(edge.from)),
                    ("to", .string(edge.to)),
                    ("lengthMeters", .number(edge.lengthMeters)),
                    ("bidirectional", .bool(edge.bidirectional)),
                    ("returns", .array(edge.returns.map { ret in
                        .object([
                            ("id", .string(ret.id)),
                            ("from", .string(ret.from)),
                            ("to", .string(ret.to)),
                            ("time", .string(dates.string(from: ret.time))),
                            ("offByMeters", .number(ret.offByMeters)),
                            ("flagged", .bool(ret.flagged)),
                            ("arrivedAt", pt(ret.arrivedAt)),
                        ])
                    })),
                ])
            })),
            ("restarts", .array(restarts.map { restart in
                .object([
                    ("atNode", .string(restart.atNode)),
                    ("time", .string(dates.string(from: restart.time))),
                    ("offByMeters", .number(restart.offByMeters)),
                    ("blocked", .bool(restart.blocked)),
                    ("measuredAt", pt(restart.measuredAt)),
                ])
            })),
            ("paths", .array(paths.map { path in
                .object([("edge", .string(path.edge)), ("points", points(path.points))])
            })),
            ("returnPaths", .array(returnPaths.map { path in
                .object([("return", .string(path.return)), ("points", points(path.points))])
            })),
        ])
        return Data((root.rendered() + "\n").utf8)
    }

    static func decode(_ data: Data) throws -> SessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFile.self, from: data)
    }
}

/// Just enough JSON to write keys in a fixed order, with short number arrays
/// (the [x, z] points) kept on one line.
private indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    func rendered(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let lines = fields.map { "\(inner)\(JSON.quoted($0.0)): \($0.1.rendered(indent: inner))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            if items.allSatisfy({ if case .number = $0 { return true } else { return false } }) {
                return "[" + items.map { $0.rendered() }.joined(separator: ", ") + "]"
            }
            let lines = items.map { inner + $0.rendered(indent: inner) }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(indent)]"
        case .string(let value):
            return JSON.quoted(value)
        case .number(let value):
            // Whole numbers without a trailing ".0"; otherwise Swift's
            // shortest round-trip form (0.03, not 0.029999999999999999).
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Rounded to the centimeter — well below ARKit's real accuracy, and `+ 0`
/// turns -0.0 into 0.0 so the file never shows "-0".
private func cm(_ value: Double) -> Double {
    (value * 100).rounded() / 100 + 0
}

private func point(_ p: Point2D) -> [Double] {
    [cm(p.x), cm(p.z)]
}

private func point2D(_ pair: [Double]) -> Point2D {
    pair.count == 2 ? Point2D(x: pair[0], z: pair[1]) : Point2D(x: 0, z: 0)
}
