import Foundation

/// Plans the shortest walk from a starting node, past every item on the list, to the cashier.
///
/// 1. Each item's location ("G44") is looked up on the map: the ways it can be picked up, either
///    a stop at one node or a lane driven end to end while scanning. Locations picked up the same
///    ways (G14 and G15 share a lane) become one group.
/// 2. Dijkstra gives the walking distance and path between every pair of nodes that matter.
/// 3. Held-Karp tries every order of groups, and every way of picking each one up, and keeps the
///    shortest. A visit also collects any other group it passes: a lane driven past a node where
///    another location is scanned picks that one up on the way. It's exact, and instant for up to
///    ~15 groups.
///
/// Walking back over a node is allowed: some spots are dead ends, and going back out of an aisle
/// can be shorter than walking through it. Collected items aren't passed in, so re-planning
/// mid-trip (`from:` the current node) only routes to what's left.
struct RoutePlanner {
    struct Item {
        let name: String
        /// "G44", or nil when the item has no location yet.
        let location: String?
    }

    /// One location scanned during a stop.
    struct Scan {
        let location: String
        let side: StoreMap.Side?
        /// The node scanned at, or the lane driven while scanning.
        let path: [String]
        let itemNames: [String]
    }

    struct Stop: Identifiable {
        /// Position in walking order, from 0.
        let id: Int
        /// The node stopped at, or the lane driven, in walking order.
        let path: [String]
        let scans: [Scan]
    }

    struct Plan {
        /// Pick-up stops, in walking order.
        let stops: [Stop]
        /// Every node walked through, from the start node to the cashier.
        let path: [String]
        let meters: Double
        /// Items with no location yet.
        let unlocated: [String]
        /// Items whose location isn't on the map ("G37").
        let unmapped: [(name: String, location: String)]
    }

    /// More groups than this would make Held-Karp slow, so the planner falls back to nearest-first.
    static let maxExactGroups = 15

    let map: StoreMap

    func plan(for items: [Item], from startId: String? = nil) -> Plan {
        let startId = startId ?? map.startId

        // Group locations by the ways they can be picked up.
        var unlocated: [String] = []
        var unmapped: [(name: String, location: String)] = []
        var groups: [Group] = []
        for item in items {
            guard let location = item.location?.uppercased() else {
                unlocated.append(item.name)
                continue
            }
            guard let visits = map.stops[location], !visits.isEmpty else {
                unmapped.append((item.name, location))
                continue
            }
            let paths = Set(visits.map(\.path))
            let index = groups.firstIndex { $0.paths == paths } ?? {
                groups.append(Group(paths: paths))
                return groups.count - 1
            }()
            groups[index].add(item.name, at: location)
        }

        // Every way to pick up each group, and which groups each one collects.
        let candidates = groups.indices.flatMap { group in
            groups[group].paths.sorted { $0.lexicographicallyPrecedes($1) }.map { Candidate(group: group, path: $0) }
        }
        let covers = candidates.map { candidate in
            groups.indices.reduce(0) { mask, group in
                groups[group].isCollected(along: candidate.path) ? mask | 1 << group : mask
            }
        }

        let graph = Graph(map: map)
        let sources = Set([startId] + candidates.flatMap(\.path))
        let trees = Dictionary(uniqueKeysWithValues: sources.map { ($0, graph.shortestPaths(from: $0)) })
        func distance(_ a: String, _ b: String) -> Double { trees[a]?.distance[b] ?? .infinity }
        let driven = candidates.map { candidate in
            zip(candidate.path, candidate.path.dropFirst()).reduce(0.0) { $0 + distance($1.0, $1.1) }
        }

        let costs = Costs(start: startId, cashier: map.cashierId, candidates: candidates,
                          covers: covers, driven: driven, distance: distance)
        let order = groups.count <= Self.maxExactGroups ? costs.exactOrder(groups: groups.count)
                                                        : costs.nearestOrder(groups: groups.count)
        if order.isEmpty && !groups.isEmpty {
            // Nothing on the list can be reached: the map is missing an edge.
            unmapped += groups.flatMap { group in
                group.locations.flatMap { location in group.items[location, default: []].map { ($0, location) } }
            }
        }

        // Expand into the walked path.
        var path = [startId]
        var meters = 0.0
        var current = startId
        func walk(to node: String) {
            guard node != current, let tree = trees[current] else { return }
            path += tree.path(to: node).dropFirst()
            meters += distance(current, node)
            current = node
        }
        var stops: [Stop] = []
        for (candidate, collected) in order {
            let lane = candidates[candidate].path
            lane.forEach(walk)
            let scans = groups.indices.filter { collected & 1 << $0 != 0 }.flatMap { group in
                groups[group].locations.map { location in
                    scan(location, items: groups[group].items[location, default: []], along: lane)
                }
            }
            stops.append(Stop(id: stops.count, path: lane, scans: scans))
        }
        if !order.isEmpty || groups.isEmpty { walk(to: map.cashierId) }

        return Plan(stops: stops, path: path, meters: meters, unlocated: unlocated, unmapped: unmapped)
    }

    /// How `location` is scanned while stopping at or driving `lane`.
    private func scan(_ location: String, items: [String], along lane: [String]) -> Scan {
        let visits = map.stops[location] ?? []
        let visit = visits.first { $0.path == lane }
            ?? visits.first { $0.path.count == 1 && lane.contains($0.path[0]) }
        return Scan(location: location, side: visit?.side, path: visit?.path ?? lane, itemNames: items)
    }
}

// MARK: - Ordering

/// Locations that are picked up the same ways.
private struct Group {
    let paths: Set<[String]>
    var locations: [String] = []
    var items: [String: [String]] = [:]

    mutating func add(_ item: String, at location: String) {
        if items[location] == nil { locations.append(location) }
        items[location, default: []].append(item)
    }

    /// Whether stopping at or driving `lane` picks this group up: it's one of the group's own ways,
    /// or the group has a stop at a node on it.
    func isCollected(along lane: [String]) -> Bool {
        paths.contains(lane) || paths.contains { $0.count == 1 && lane.contains($0[0]) }
    }
}

/// One way to pick up a group.
private struct Candidate {
    let group: Int
    /// The node stopped at, or the lane driven, in order.
    let path: [String]
}

private struct Costs {
    let start: String
    let cashier: String
    let candidates: [Candidate]
    /// Bit mask of the groups each candidate collects.
    let covers: [Int]
    /// Meters walked inside each candidate: 0 for a stop, the lane's length for a lane.
    let driven: [Double]
    let distance: (String, String) -> Double

    private func entry(_ candidate: Int) -> String { candidates[candidate].path[0] }
    private func exit(_ candidate: Int) -> String { candidates[candidate].path[candidates[candidate].path.count - 1] }

    /// Held-Karp over (groups collected, last candidate). Returns candidates in walking order, each
    /// with the groups it newly collects, for the shortest start → every group → cashier walk.
    func exactOrder(groups: Int) -> [(candidate: Int, collected: Int)] {
        guard groups > 0 else { return [] }
        let full = (1 << groups) - 1
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: candidates.count), count: full + 1)
        var previous = [[(mask: Int, candidate: Int)?]](repeating: [(mask: Int, candidate: Int)?](repeating: nil, count: candidates.count), count: full + 1)

        for index in candidates.indices {
            let total = distance(start, entry(index)) + driven[index]
            if total < cost[covers[index]][index] { cost[covers[index]][index] = total }
        }
        // Every step collects at least one new group, so masks only grow.
        for mask in 1...full {
            for index in candidates.indices where cost[mask][index] < .infinity {
                for next in candidates.indices where mask & 1 << candidates[next].group == 0 {
                    let nextMask = mask | covers[next]
                    let total = cost[mask][index] + distance(exit(index), entry(next)) + driven[next]
                    if total < cost[nextMask][next] {
                        cost[nextMask][next] = total
                        previous[nextMask][next] = (mask, index)
                    }
                }
            }
        }

        // Best last candidate, counting the walk to the cashier.
        guard let best = candidates.indices
            .map({ (index: $0, total: cost[full][$0] + distance(exit($0), cashier)) })
            .filter({ $0.total < .infinity })
            .min(by: { $0.total < $1.total }) else { return [] }

        var order: [(candidate: Int, collected: Int)] = []
        var mask = full
        var index = best.index
        while true {
            let before = previous[mask][index]
            order.append((index, mask & ~(before?.mask ?? 0)))
            guard let before else { break }
            (mask, index) = before
        }
        return order.reversed()
    }

    /// Fallback for long lists: always go to the closest way to pick up a group not yet collected.
    func nearestOrder(groups: Int) -> [(candidate: Int, collected: Int)] {
        var left = (1 << groups) - 1
        var current = start
        var order: [(candidate: Int, collected: Int)] = []
        while let next = candidates.indices
            .filter({ left & 1 << candidates[$0].group != 0 })
            .min(by: { distance(current, entry($0)) + driven[$0] < distance(current, entry($1)) + driven[$1] }) {
            guard distance(current, entry(next)) < .infinity else { break }
            order.append((next, covers[next] & left))
            left &= ~covers[next]
            current = exit(next)
        }
        return order
    }
}

// MARK: - Shortest paths

private struct Graph {
    struct Tree {
        let distance: [String: Double]
        let previous: [String: String]

        /// Nodes from the tree's source to `node`, both included.
        func path(to node: String) -> [String] {
            var path = [node]
            while let before = previous[path[path.count - 1]] { path.append(before) }
            return path.reversed()
        }
    }

    private var neighbors: [String: [(node: String, meters: Double)]] = [:]

    init(map: StoreMap) {
        // Every edge can be walked both ways.
        for edge in map.edges {
            let meters = map.length(of: edge)
            neighbors[edge.from, default: []].append((edge.to, meters))
            neighbors[edge.to, default: []].append((edge.from, meters))
        }
    }

    /// Dijkstra. The map is a few dozen nodes, so a linear scan for the closest node is plenty.
    func shortestPaths(from source: String) -> Tree {
        var distance = [source: 0.0]
        var previous: [String: String] = [:]
        var done = Set<String>()
        while let (node, here) = distance.filter({ !done.contains($0.key) }).min(by: { $0.value < $1.value }) {
            done.insert(node)
            for (next, meters) in neighbors[node] ?? [] where here + meters < distance[next] ?? .infinity {
                distance[next] = here + meters
                previous[next] = node
            }
        }
        return Tree(distance: distance, previous: previous)
    }
}
