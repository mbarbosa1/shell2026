import SwiftUI
import ARKit
import SceneKit

/// Camera passthrough only — we drive the ARSession directly via
/// CalibrationManager and never add SceneKit content, so this is just a
/// live viewfinder, not a rendering pipeline.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session   // NOTE: verify this is settable in your SDK version;
                                  // if not, drive `manager.arSession` as the view's
                                  // own `.session` instead of constructing a separate one.
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct CalibrationView: View {
    @StateObject private var manager = CalibrationManager()

    @State private var showNewNodeAlert = false
    @State private var showReturnPicker = false
    @State private var showResetConfirm = false
    @State private var showHeadingDiagnostic = false
    @State private var showPriorSessions = false
    @State private var newNodeName = ""
    @State private var hasStarted = false

    var body: some View {
        ZStack {
            ARCameraView(session: manager.arSession)
                .ignoresSafeArea()

            VStack {
                statusBar

                if showHeadingDiagnostic {
                    headingDiagnosticBar
                }

                if manager.segmentInterrupted {
                    interruptionBanner
                }

                Spacer()

                if let msg = manager.lastMessage {
                    Text(msg)
                        .padding(8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.horizontal)
                }

                Text(String(format: "Since last node: %.2f m", manager.distanceSinceLastNode))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(6)

                controlBar
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            if !hasStarted {
                manager.start(storeName: "Target - Waterford Lakes")
                hasStarted = true
            }
        }
        .alert("Name this location", isPresented: $showNewNodeAlert) {
            TextField("e.g. Aisle 26 Top", text: $newNodeName)
            Button("Save") {
                let name = newNodeName.isEmpty ? "Node \(manager.session.nodes.count + 1)" : newNodeName
                manager.markNewNode(name: name)
                newNodeName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showReturnPicker) {
            NodePickerView(nodes: manager.session.nodes.filter { $0.id != manager.lastNodeId }) { picked in
                manager.markReturnToNode(nodeId: picked.id)
                showReturnPicker = false
            }
        }
        .sheet(isPresented: $showPriorSessions) {
            PriorSessionsView(files: manager.priorSessionFiles)
        }
        .alert("Reset active session?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { manager.resetActiveSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears every node and edge from the active session and starts a new file. The current session's file stays on disk under Prior Sessions.")
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
            Text(statusText)
                .foregroundColor(.white)
                .font(.caption)
            Spacer()
            Button(showHeadingDiagnostic ? "Hide heading" : "Show heading") {
                showHeadingDiagnostic.toggle()
            }
            .font(.caption)
            Spacer()
            Text("\(manager.session.nodes.count) nodes")
                .foregroundColor(.white)
                .font(.caption)
        }
        .padding()
        .background(Color.black.opacity(0.5))
    }

    private var headingDiagnosticBar: some View {
        VStack(spacing: 2) {
            Text("Live heading: \(String(format: "%.1f°", manager.liveYawDegrees))")
                .font(.headline)
            Text("Starts near 0°. Rotate phone LEFT a quarter turn — it should read about +90°. If it reads −90°, flip the sign in yawDegrees() before trusting turn logic.")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private var interruptionBanner: some View {
        VStack(spacing: 6) {
            Text("⚠️ Tracking was interrupted")
                .font(.headline)
            Text("This segment's path can't be trusted. Walk back to the last confirmed node, then tap Restart Segment.")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Restart Segment") {
                manager.restartSegment()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!manager.trackingQuality.canMarkNode)
            if !manager.trackingQuality.canMarkNode {
                Text("Waiting for tracking to recover…")
                    .font(.caption2)
            }
        }
        .foregroundColor(.white)
        .padding(10)
        .background(Color.red.opacity(0.85))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var statusColor: Color {
        switch manager.trackingQuality {
        case .good: return manager.segmentInterrupted ? .orange : .green
        case .degraded: return .yellow
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        if manager.segmentInterrupted { return "Segment interrupted — restart required" }
        switch manager.trackingQuality {
        case .good: return "Tracking stable"
        case .degraded(let reason): return reason
        case .unavailable: return "No tracking"
        }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button("New Location") { showNewNodeAlert = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.trackingQuality.canMarkNode || manager.segmentInterrupted)

                Button("Return to Existing") { showReturnPicker = true }
                    .buttonStyle(.bordered)
                    .disabled(!manager.trackingQuality.canMarkNode || manager.segmentInterrupted || !manager.session.nodes.contains { $0.id != manager.lastNodeId })
            }

            HStack(spacing: 12) {
                Button("Undo Last") { manager.undoLast() }
                    .buttonStyle(.bordered)

                if #available(iOS 16.0, *) {
                    ShareLink(item: manager.exportFileURL()) {
                        Text("Export Current")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Export via Xcode ▸ Devices")
                        .font(.caption2)
                        .foregroundColor(.white)
                }

                Button("Prior Sessions") { showPriorSessions = true }
                    .buttonStyle(.bordered)
                    .disabled(manager.priorSessionFiles.isEmpty)

                Button("Reset", role: .destructive) { showResetConfirm = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.black.opacity(0.4))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

private struct NodePickerView: View {
    let nodes: [NodeRecord]
    let onPick: (NodeRecord) -> Void

    var body: some View {
        NavigationView {
            List(nodes) { node in
                Button(node.name) { onPick(node) }
            }
            .navigationTitle("Which location is this?")
        }
    }
}

/// Read-only. These files are from PAST app launches, each with its own
/// unrelated coordinate origin — they are listed here for export only and
/// are never loaded back into the active recording session.
private struct PriorSessionsView: View {
    let files: [URL]

    var body: some View {
        NavigationView {
            List(files, id: \.self) { file in
                if #available(iOS 16.0, *) {
                    ShareLink(item: file) {
                        Text(file.lastPathComponent)
                    }
                } else {
                    Text(file.lastPathComponent)
                }
            }
            .navigationTitle("Prior Sessions (export only)")
        }
    }
}
