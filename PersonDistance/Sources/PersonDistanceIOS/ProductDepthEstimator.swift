#if os(iOS)
@_exported import PersonDistanceCore
import ARKit
import CoreGraphics
import CoreVideo
import simd

/// What one ARKit frame gives for a reading, taken off the `ARFrame` straight away: holding
/// frames stalls ARKit's camera. The box that is measured and the depth it is measured in come
/// from the same frame (README, "Rules"), never from a newer one.
///
/// Sendable because nothing writes to it or its buffers after it's taken; it's only read.
public struct CameraSnapshot: @unchecked Sendable {
    /// ARKit's landscape camera image. Boxes and points passed to this package are in its pixels.
    public let image: CVPixelBuffer
    public let imageSize: CGSize
    /// `ARFrame.timestamp`.
    public let time: TimeInterval
    /// LiDAR depth in meters from the camera plane, and ARKit's confidence in each pixel. Nil
    /// while depth is off (before the shopper's Yes) or on a frame that has none yet.
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
    let intrinsics: CameraIntrinsics
    /// Camera to world (`ARCamera.transform`), for points that must outlast this frame.
    let cameraToWorld: simd_float4x4

    @MainActor
    public init(_ frame: ARFrame) {
        image = frame.capturedImage
        imageSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        time = frame.timestamp
        depth = frame.sceneDepth?.depthMap
        confidence = frame.sceneDepth?.confidenceMap
        let k = frame.camera.intrinsics
        intrinsics = CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
                                      resolution: frame.camera.imageResolution)
        cameraToWorld = frame.camera.transform
    }

    /// True when the frame has LiDAR depth.
    public var hasDepth: Bool { depth != nil }

    /// Confident depths (meters from the camera plane) in a window of the depth map.
    func depths(in window: (x: ClosedRange<Int>, y: ClosedRange<Int>)) -> [Float] {
        guard let map = depth else { return [] }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(map) else { return [] }
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
        return depths
    }

    /// The depth map's size in pixels, or nil without depth.
    var depthSize: (width: Int, height: Int)? {
        depth.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
    }

    /// The world point seen at `point` (image pixels) at camera-plane depth `z`.
    func worldPoint(planeDepth z: Double, at point: CGPoint) -> SIMD3<Float> {
        let camera = DepthGeometry.arkitCameraPoint(
            DepthGeometry.cameraPoint(planeDepth: z, at: point, imageSize: imageSize, intrinsics: intrinsics))
        let world = cameraToWorld * SIMD4(Float(camera.x), Float(camera.y), Float(camera.z), 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// Camera-plane depth of a world point in this frame: how far in front of the camera it is.
    func planeDepth(of world: SIMD3<Float>) -> Double {
        let camera = cameraToWorld.inverse * SIMD4(world, 1)
        return Double(-camera.z)
    }
}

/// A product's LiDAR reading, and where the middle of its box is in the world.
struct ProductReading {
    let sample: DistanceSample
    let worldPoint: SIMD3<Float>
}

/// Meters from the phone's camera to one product, from LiDAR scene depth.
///
/// The reading is the median of the medium- and high-confidence depth samples in the middle half
/// of the product's box, turned from distance-to-the-camera-plane into straight-line range with
/// the camera's intrinsics. Whether it is good enough to use is `SpatialValidityPolicy`'s call.
enum ProductDepthEstimator {
    /// Nil when the frame has no depth, or no confident depth over the box.
    /// - Parameter box: in `frame.image`'s pixels from its top left.
    static func reading(of box: CGRect, in frame: CameraSnapshot) -> ProductReading? {
        guard let size = frame.depthSize,
              let window = DepthGeometry.window(for: box, imageSize: frame.imageSize,
                                                depthWidth: size.width, depthHeight: size.height) else { return nil }
        let depths = frame.depths(in: window)
        guard let summary = DepthGeometry.summarize(depths, considered: window.x.count * window.y.count) else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)
        let meters = DepthGeometry.range(planeDepth: summary.median, at: centre,
                                         imageSize: frame.imageSize, intrinsics: frame.intrinsics)
        return ProductReading(
            sample: DistanceSample(meters: meters, coverage: summary.coverage, spread: summary.spread, frameTime: frame.time),
            worldPoint: frame.worldPoint(planeDepth: summary.median, at: centre))
    }

    /// The fingertip against a product whose middle is at `product` (world). Nil without confident
    /// depth at the fingertip.
    /// - Parameter fingertip: in `frame.image`'s pixels from its top left.
    static func hand(at fingertip: CGPoint, reaching product: SIMD3<Float>, in frame: CameraSnapshot) -> HandSample? {
        // Two depth pixels either side: about the width of a fingertip at arm's length.
        guard let size = frame.depthSize,
              let window = DepthGeometry.window(around: fingertip, radius: 2, imageSize: frame.imageSize,
                                                depthWidth: size.width, depthHeight: size.height),
              let z = DepthGeometry.nearestSurface(frame.depths(in: window)) else { return nil }
        let finger = frame.worldPoint(planeDepth: z, at: fingertip)
        return HandSample(meters: Double(simd_distance(finger, product)),
                          gap: frame.planeDepth(of: product) - z, frameTime: frame.time)
    }
}
#endif
