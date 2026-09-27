#if os(iOS)
@_exported import PersonDistanceCore
import ARKit
import CoreGraphics
import CoreVideo

/// What one ARKit frame gives for a reading, taken off the `ARFrame` straight away: holding
/// frames stalls ARKit's camera. The box that is measured and the depth it is measured in come
/// from the same frame (README step 6), never from a newer one.
///
/// Sendable because nothing writes to it or its buffers after it's taken; it's only read, on
/// `ProductRangeSession`'s one Vision queue.
struct DepthFrame: @unchecked Sendable {
    /// ARKit's landscape camera image, the one the product's box is tracked in.
    let image: CVPixelBuffer
    let imageSize: CGSize
    /// `ARFrame.timestamp`.
    let time: TimeInterval
    /// LiDAR depth in meters from the camera plane, and ARKit's confidence in each pixel. Nil
    /// while depth is off (before the shopper's Yes) or on a frame that has none yet.
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
    let intrinsics: CameraIntrinsics

    @MainActor
    init(_ frame: ARFrame) {
        image = frame.capturedImage
        imageSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        time = frame.timestamp
        depth = frame.sceneDepth?.depthMap
        confidence = frame.sceneDepth?.confidenceMap
        let k = frame.camera.intrinsics
        intrinsics = CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
                                      resolution: frame.camera.imageResolution)
    }
}

/// Meters from the phone's camera to one product, from LiDAR scene depth.
///
/// The reading is the median of the medium- and high-confidence depth samples in the middle half
/// of the product's box, turned from distance-to-the-camera-plane into straight-line range with
/// the camera's intrinsics. Whether it is good enough to use is `SpatialValidityPolicy`'s call.
enum ProductDepthEstimator {
    /// Nil when the frame has no depth, or no confident depth over the box.
    /// - Parameter box: in `frame.image`'s pixels from its top left.
    static func sample(of box: CGRect, in frame: DepthFrame) -> DistanceSample? {
        guard let map = frame.depth else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard let window = DepthGeometry.window(for: box, imageSize: frame.imageSize,
                                                depthWidth: width, depthHeight: height) else { return nil }

        let confidence = frame.confidence
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(map) else { return nil }
        let depthRow = CVPixelBufferGetBytesPerRow(map)
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceRow = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0

        var depths: [Float] = []
        depths.reserveCapacity(window.x.count * window.y.count)
        for y in window.y {
            let meters = (depthBase + y * depthRow).assumingMemoryBound(to: Float32.self)
            let levels = confidenceBase.map { ($0 + y * confidenceRow).assumingMemoryBound(to: UInt8.self) }
            for x in window.x {
                if let levels, levels[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let z = meters[x]
                if z.isFinite, z > 0 { depths.append(z) }
            }
        }
        guard let summary = DepthGeometry.summarize(depths, considered: window.x.count * window.y.count) else { return nil }
        let meters = DepthGeometry.range(planeDepth: summary.median, at: CGPoint(x: box.midX, y: box.midY),
                                         imageSize: frame.imageSize, intrinsics: frame.intrinsics)
        return DistanceSample(meters: meters, coverage: summary.coverage, spread: summary.spread, frameTime: frame.time)
    }
}
#endif
