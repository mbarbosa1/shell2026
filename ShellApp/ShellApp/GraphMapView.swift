import SwiftUI

/// Top-down 2D drawing of a calibration graph: every edge's recorded
/// breadcrumb trail labeled with its walked length, and every node at its
/// canonical position.
///
/// Orientation: screen UP = the direction the camera faced when the AR
/// session started (ARKit -Z), screen RIGHT = ARKit +X. Not mirrored — a
/// left turn on the floor is a left turn on screen.
///
/// Pinch to zoom, drag to pan, double-tap to refit.
struct GraphMapView: View {
    let session: CalibrationSessionData
    /// Highlighted as "you are here" on the live map. nil for prior sessions.
    var currentNodeId: String? = nil

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        if session.nodes.isEmpty {
            ContentUnavailableView("No nodes yet",
                                   systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Mark a location to start the map."))
        } else {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .background(Color(.systemBackground))
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = min(max(zoom * $0.magnification, 0.5), 30) },
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
            .safeAreaInset(edge: .bottom) { legend }
        }
    }

    private var legend: some View {
        let total = session.edges.reduce(0) { $0 + $1.breadcrumbs.pathLength }
        return VStack(spacing: 6) {
            HStack(spacing: 14) {
                legendDot(.green, "Entrance")
                if currentNodeId != nil { legendDot(.yellow, "Current") }
                legendLine(.blue, "Edge")
                legendLine(.orange, "Drift > threshold")
            }
            Text("\(session.nodes.count) nodes · \(session.edges.count) edges · \(String(format: "%.1f", total)) m walked")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func legendLine(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 4)
            Text(label)
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Fit every recorded point (nodes AND trails — a trail can bulge
        // well outside the nodes it connects) with some margin.
        let allPoints = session.nodes.map(\.position) + session.edges.flatMap(\.breadcrumbs)
        let minX = allPoints.map(\.x).min()!, maxX = allPoints.map(\.x).max()!
        let minZ = allPoints.map(\.z).min()!, maxZ = allPoints.map(\.z).max()!
        let margin: CGFloat = 50
        let fitScale = min((size.width - 2 * margin) / max(maxX - minX, 1),
                           (size.height - 2 * margin) / max(maxZ - minZ, 1))
        let scale = fitScale * zoom * pinch
        let centerX = (minX + maxX) / 2, centerZ = (minZ + maxZ) / 2

        func screen(_ p: Point2D) -> CGPoint {
            CGPoint(x: size.width / 2 + (p.x - centerX) * scale + pan.width + drag.width,
                    y: size.height / 2 + (p.z - centerZ) * scale + pan.height + drag.height)
        }

        let nodesById = Dictionary(uniqueKeysWithValues: session.nodes.map { ($0.id, $0) })

        // Edges first so nodes draw on top.
        for edge in session.edges {
            var trail = edge.breadcrumbs
            if trail.count < 2, let a = nodesById[edge.fromNodeId], let b = nodesById[edge.toNodeId] {
                trail = [a.position, b.position]
            }
            guard trail.count >= 2 else { continue }

            let drifted = edge.visitObservations.contains { $0.flagged }
            let color: Color = drifted ? .orange : .blue

            var path = Path()
            path.addLines(trail.map(screen))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            // Skip the label when the edge is too short on screen to fit it
            // without covering the nodes — zoom in to see those.
            let length = trail.pathLength
            if length * scale > 40 {
                drawLabel(String(format: "%.1f m", length), at: screen(trail.pointAtHalfLength),
                          fill: color, textColor: .white, in: &context)
            }
        }

        for (index, node) in session.nodes.enumerated() {
            let p = screen(node.position)
            let fill: Color = node.id == currentNodeId ? .yellow : (index == 0 ? .green : .white)
            let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            context.fill(dot, with: .color(fill))
            context.stroke(dot, with: .color(.black), lineWidth: 2)
            drawLabel(node.name, at: CGPoint(x: p.x, y: p.y - 20),
                      fill: Color(.systemBackground).opacity(0.85), textColor: .primary, in: &context)
        }

        // Starting direction, drawn last so node labels can't hide it. Fixed
        // on-screen length so it stays readable at any zoom.
        if let start = session.startPose {
            let radians = start.headingDegrees * .pi / 180
            let base = screen(start.position)
            // World forward (-sin, -cos) in (x, z) maps directly to screen (x, y).
            let tip = CGPoint(x: base.x - sin(radians) * 36, y: base.y - cos(radians) * 36)
            var arrow = Path()
            arrow.move(to: base)
            arrow.addLine(to: tip)
            context.stroke(arrow, with: .color(.green), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 4]))
            let head = Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8))
            context.fill(head, with: .color(.green))
        }

        drawScaleBar(scale: scale, size: size, in: &context)
    }

    private func drawLabel(_ string: String, at point: CGPoint, fill: Color, textColor: Color,
                           in context: inout GraphicsContext) {
        let text = context.resolve(Text(string).font(.caption2.bold()).foregroundStyle(textColor))
        let textSize = text.measure(in: CGSize(width: 240, height: 40))
        let box = CGRect(x: point.x - textSize.width / 2 - 4, y: point.y - textSize.height / 2 - 2,
                         width: textSize.width + 8, height: textSize.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(fill))
        context.draw(text, at: point)
    }

    /// Largest round length that fits in ~120pt, drawn bottom-left.
    private func drawScaleBar(scale: CGFloat, size: CGSize, in context: inout GraphicsContext) {
        let meters = [0.5, 1, 2, 5, 10, 20, 50, 100].last { $0 * scale <= 120 } ?? 0.5
        let width = meters * scale
        let origin = CGPoint(x: 16, y: size.height - 24)
        var bar = Path()
        bar.move(to: CGPoint(x: origin.x, y: origin.y - 5))
        bar.addLine(to: origin)
        bar.addLine(to: CGPoint(x: origin.x + width, y: origin.y))
        bar.addLine(to: CGPoint(x: origin.x + width, y: origin.y - 5))
        context.stroke(bar, with: .color(.primary), lineWidth: 2)
        let label = meters < 1 ? String(format: "%.1f m", meters) : "\(Int(meters)) m"
        context.draw(context.resolve(Text(label).font(.caption2)),
                     at: CGPoint(x: origin.x + width / 2, y: origin.y - 12))
    }
}

private extension Array where Element == Point2D {
    /// The point halfway along the trail by walked distance — where the
    /// edge's length label goes, so it sits on the path even when curved.
    var pointAtHalfLength: Point2D {
        var remaining = pathLength / 2
        for (a, b) in zip(self, dropFirst()) {
            let step = a.distance(to: b)
            if step >= remaining, step > 0 {
                let t = remaining / step
                return Point2D(x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t)
            }
            remaining -= step
        }
        return last ?? Point2D(x: 0, z: 0)
    }
}

#Preview("Sample store") {
    func line(_ a: Point2D, _ b: Point2D) -> [Point2D] {
        let steps = max(Int(a.distance(to: b) / 0.3), 1)
        return (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return Point2D(x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t)
        }
    }
    let entrance = NodeRecord(id: "e", name: "Entrance", position: Point2D(x: 0, z: 0))
    let walkway = NodeRecord(id: "w", name: "Walkway", position: Point2D(x: 0, z: -8))
    let a26f = NodeRecord(id: "a", name: "A26 Front", position: Point2D(x: 6, z: -8))
    let a26b = NodeRecord(id: "b", name: "A26 Back", position: Point2D(x: 6, z: -20))
    let a27f = NodeRecord(id: "c", name: "A27 Front", position: Point2D(x: 9, z: -8))
    var drifted = EdgeRecord(id: "4", fromNodeId: "a", toNodeId: "c",
                             breadcrumbs: line(a26f.position, a27f.position), bidirectional: true)
    drifted.visitObservations = [VisitObservation(fromNodeId: "c", toNodeId: "a",
                                                  arrivalPosition: Point2D(x: 7.3, z: -8.4),
                                                  discrepancy: 1.36, timestamp: .now, flagged: true)]
    var session = CalibrationSessionData(storeName: "Sample")
    session.startPose = StartPose(position: entrance.position, headingDegrees: 0)
    session.nodes = [entrance, walkway, a26f, a26b, a27f]
    session.edges = [
        EdgeRecord(id: "1", fromNodeId: "e", toNodeId: "w",
                   breadcrumbs: line(entrance.position, walkway.position), bidirectional: true),
        EdgeRecord(id: "2", fromNodeId: "w", toNodeId: "a",
                   breadcrumbs: line(walkway.position, a26f.position), bidirectional: true),
        EdgeRecord(id: "3", fromNodeId: "a", toNodeId: "b",
                   breadcrumbs: line(a26f.position, a26b.position), bidirectional: true),
        drifted,
    ]
    return GraphMapView(session: session, currentNodeId: "c")
}
