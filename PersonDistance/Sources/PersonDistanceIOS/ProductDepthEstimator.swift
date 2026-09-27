import ARKit
import CoreGraphics
import CoreVideo

/// Meters from the phone's camera to one product in view.
///
/// **Interim, display-only** (README, "Interim display readout"): ShellApp shows the number on the
/// camera screen while it looks for an item. Nothing is decided or spoken from it. It follows two of
/// the plan's rules: one product only, and LiDAR scene depth. It doesn't meet the rest yet: it
/// measures before automatic confirmation, and it reads ARKit's latest frame rather than the frame
/// recognition checked, so the box can be a fraction of a second old.
///
/// With scene depth, the reading is the median of the confident depth samples in the middle half of
/// the product's box, turned from distance-to-the-camera-plane into straight-line range with the
/// camera's intrinsics. Without it (no LiDAR, or no depth on this frame yet), it's an ARKit raycast
/// from the box's centre against surfaces ARKit estimates.
@MainActor
public struct ProductDepthEstimator {
    private let session: ARSession

    /// `session` is the app's one ARKit session; this only reads its frames.
    public init(session: ARSession) {
        self.session = session
    }

    /// Adds LiDAR scene depth to the camera's configuration when the phone has LiDAR. Other phones'
    /// configuration is left as it is.
    public static func enableSceneDepth(in configuration: ARWorldTrackingConfiguration) {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { return }
        configuration.frameSemantics.insert(.sceneDepth)
    }

    /// Meters to the product, or nil when there isn't exactly one product to measure or no reading.
    ///
    /// Boxes are in the camera image's pixels from its top left (ARKit's landscape image).
    /// - Parameters:
    ///   - focused: the object recognition matched when several were in view.
    ///   - region: the object region the frame found. It covers every object in view.
    ///   - objectCount: how many objects `region` covers.
    ///   - imageSize: the camera image's size in pixels.
    public func range(focused: CGRect?, region: CGRect?, objectCount: Int, imageSize: CGSize) -> Double? {
        // One product only: a region around several objects isn't one surface.
        guard let box = focused ?? (objectCount == 1 ? region : nil),
              imageSize.width > 0, imageSize.height > 0,
              let frame = session.currentFrame else { return nil }
        if let depth = frame.sceneDepth {
            return sceneRange(to: box, imageSize: imageSize, depth: depth, camera: frame.camera)
        }
        let centre = CGPoint(x: box.midX / imageSize.width, y: box.midY / imageSize.height)
        return raycastRange(to: centre, in: frame)
    }

    // MARK: Scene depth

    private func sceneRange(to box: CGRect, imageSize: CGSize, depth: ARDepthData, camera: ARCamera) -> Double? {
        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        // The depth map sees what the camera image sees, at a lower resolution.
        let sx = CGFloat(width) / imageSize.width, sy = CGFloat(height) / imageSize.height
        // The middle half of the box: the product's own surface, clear of its edges and what's behind.
        let inner = box.insetBy(dx: box.width / 4, dy: box.height / 4)
        let x0 = max(Int(inner.minX * sx), 0), x1 = min(Int(inner.maxX * sx), width - 1)
        let y0 = max(Int(inner.minY * sy), 0), y1 = min(Int(inner.maxY * sy), height - 1)
        guard x0 <= x1, y0 <= y1 else { return nil }

        let confidence = depth.confidenceMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(map) else { return nil }
        let depthRow = CVPixelBufferGetBytesPerRow(map)
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceRow = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0

        var samples: [Float] = []
        samples.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 {
            let meters = (depthBase + y * depthRow).assumingMemoryBound(to: Float32.self)
            let levels = confidenceBase.map { ($0 + y * confidenceRow).assumingMemoryBound(to: UInt8.self) }
            for x in x0...x1 {
                if let levels, levels[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let z = meters[x]
                if z.isFinite, z > 0 { samples.append(z) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let z = Double(samples[samples.count / 2])

        // Depth is measured from the camera plane. A product off the lens axis is farther than that,
        // by the length of its ray through the image: sqrt(1 + ((u - cx) / fx)² + ((v - cy) / fy)²).
        let k = camera.intrinsics
        let fx = Double(k[0][0]), fy = Double(k[1][1]), cx = Double(k[2][0]), cy = Double(k[2][1])
        guard fx > 0, fy > 0 else { return z }
        // The intrinsics are for `camera.imageResolution`, the same image as `box` but checked anyway.
        let u = Double(box.midX * camera.imageResolution.width / imageSize.width)
        let v = Double(box.midY * camera.imageResolution.height / imageSize.height)
        return z * ((1 + pow((u - cx) / fx, 2) + pow((v - cy) / fy, 2))).squareRoot()
    }

    // MARK: Raycast (no LiDAR)

    /// `point` is 0…1 from the top left of the camera image.
    private func raycastRange(to point: CGPoint, in frame: ARFrame) -> Double? {
        let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else { return nil }
        let camera = frame.camera.transform.columns.3
        let spot = hit.worldTransform.columns.3
        return Double(simd_distance(SIMD3(camera.x, camera.y, camera.z), SIMD3(spot.x, spot.y, spot.z)))
    }
}
