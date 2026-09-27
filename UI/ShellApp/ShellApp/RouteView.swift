import SwiftUI

/// The shortest route for what's left on the list: drawn on the store map, then listed stop by stop.
struct RouteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let map = StoreMap.target

    private var plan: RoutePlanner.Plan {
        let items = model.items
            .filter { !$0.isCollected }
            .map { RoutePlanner.Item(name: $0.name, location: $0.location) }
        return RoutePlanner(map: map).plan(for: items)
    }

    var body: some View {
        let plan = plan
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StoreMapView(map: map, path: plan.path, stops: plan.stops.map(\.path))
                        .frame(height: 360)
                        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))

                    Text("About \(Int(plan.meters.rounded())) m · " + (plan.stops.count == 1 ? "1 stop" : "\(plan.stops.count) stops"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    VStack(spacing: 8) {
                        ForEach(plan.stops) { stop in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(stop.id + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(Theme.accentText)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(of: stop))
                                        .font(.headline)
                                    ForEach(stop.scans, id: \.location) { scan in
                                        Text("Scan \(scan.location)" + (scan.side.map { " facing \($0.rawValue)" } ?? "")
                                             + (stop.path.count > 1 && scan.path.count == 1 ? " at \(name(scan.path[0]))" : "")
                                             + ": \(scan.itemNames.joined(separator: ", "))")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            .cardStyle()
                        }
                    }

                    if !plan.unmapped.isEmpty {
                        note("Not on the map yet", plan.unmapped.map { "\($0.name) (\($0.location))" })
                    }
                    if !plan.unlocated.isEmpty {
                        note("No aisle yet", plan.unlocated)
                    }
                }
                .padding(16)
            }
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if plan.stops.isEmpty && plan.unmapped.isEmpty && plan.unlocated.isEmpty {
                    ContentUnavailableView("Nothing left to get", systemImage: "cart",
                                           description: Text("Add items to your list to plan a route."))
                }
            }
        }
    }

    /// "Stop at Node 10" or "Drive Node 14 → Node 3".
    private func title(of stop: RoutePlanner.Stop) -> String {
        stop.path.count == 1
            ? "Stop at \(name(stop.path[0]))"
            : "Drive \(name(stop.path[0])) → \(name(stop.path[stop.path.count - 1]))"
    }

    private func name(_ id: String) -> String { map.node(id)?.name ?? id }

    private func note(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(names.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}

/// Top-down drawing of the store graph with a route on top. Pinch to zoom, drag to pan,
/// double-tap to refit.
struct StoreMapView: View {
    let map: StoreMap
    var path: [String] = []
    /// Where items are picked up, numbered in order: one node, or a lane driven while scanning.
    var stops: [[String]] = []

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .contentShape(.rect)
        .gesture(
            SimultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { zoom = min(max(zoom * $0.magnification, 0.5), 20) },
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded {
                        pan.width += $0.translation.width
                        pan.height += $0.translation.height
                    }
            )
        )
        .onTapGesture(count: 2) {
            zoom = 1
            pan = .zero
        }
        .accessibilityElement()
        .accessibilityLabel("Store map with your route")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !map.nodes.isEmpty else { return }
        let minX = map.nodes.map(\.x).min()!, maxX = map.nodes.map(\.x).max()!
        let minY = map.nodes.map(\.y).min()!, maxY = map.nodes.map(\.y).max()!
        let margin: CGFloat = 24
        let fit = min((size.width - 2 * margin) / max(maxX - minX, 1),
                      (size.height - 2 * margin) / max(maxY - minY, 1))
        let scale = fit * zoom * pinch
        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
        let nodesById = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })

        // Map y runs up, screen y runs down.
        func screen(_ node: StoreMap.Node) -> CGPoint {
            CGPoint(x: size.width / 2 + (node.x - centerX) * scale + pan.width + drag.width,
                    y: size.height / 2 - (node.y - centerY) * scale + pan.height + drag.height)
        }

        for edge in map.edges {
            guard let a = nodesById[edge.from], let b = nodesById[edge.to] else { continue }
            var line = Path()
            line.move(to: screen(a))
            line.addLine(to: screen(b))
            context.stroke(line, with: .color(Theme.textSecondary.opacity(0.35)), lineWidth: 2)
        }

        let routePoints = path.compactMap { nodesById[$0] }.map(screen)
        if routePoints.count >= 2 {
            var route = Path()
            route.addLines(routePoints)
            context.stroke(route, with: .color(Theme.lavender),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }

        for node in map.nodes {
            let p = screen(node)
            let color: Color = switch node.kind {
            case .start: Theme.success
            case .cashier: .orange
            case .scan: Theme.textSecondary
            case .walkway: Theme.textSecondary.opacity(0.5)
            }
            let radius: CGFloat = node.kind == .walkway ? 2.5 : 4
            context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color))
        }

        for (index, stop) in stops.enumerated() {
            let points = stop.compactMap { nodesById[$0] }.map(screen)
            guard let first = points.first else { continue }
            if points.count >= 2 {
                var lane = Path()
                lane.addLines(points)
                context.stroke(lane, with: .color(Theme.success),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            let p = first
            context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(Theme.lavender))
            context.draw(context.resolve(Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(Theme.onLavender)), at: p)
        }

        for (id, label) in [(map.startId, "Start"), (map.cashierId, "Cashier")] {
            guard let node = nodesById[id] else { continue }
            let p = screen(node)
            context.draw(context.resolve(Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)),
                         at: CGPoint(x: p.x, y: p.y + 12))
        }
    }
}

#Preview {
    RouteView()
        .environment(AppModel.preview)
        .preferredColorScheme(.dark)
}
