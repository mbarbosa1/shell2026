import CoreGraphics
import Foundation

/// The camera's focal lengths and optical centre in pixels, for an image of `resolution`
/// (ARKit's `ARCamera.intrinsics` and `imageResolution`).
public struct CameraIntrinsics: Equatable, Sendable {
    public let fx: Double, fy: Double, cx: Double, cy: Double
    public let resolution: CGSize

    public init(fx: Double, fy: Double, cx: Double, cy: Double, resolution: CGSize) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.resolution = resolution
    }
}

/// The arithmetic behind a scene-depth reading, kept apart from ARKit so it can be tested.
///
/// Boxes are in the camera image's pixels from its top left (ARKit's landscape `capturedImage`,
/// not turned for the upright phone). The depth map sees the same image at a lower resolution.
public enum DepthGeometry {
    /// Depth-map pixels to read for a product: the middle half of its box, which is the product's
    /// own surface, clear of its edges and whatever is behind them. Nil when that falls outside
    /// the map.
    public static func window(for box: CGRect, imageSize: CGSize, depthWidth: Int, depthHeight: Int)
        -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard imageSize.width > 0, imageSize.height > 0, depthWidth > 0, depthHeight > 0 else { return nil }
        let sx = CGFloat(depthWidth) / imageSize.width, sy = CGFloat(depthHeight) / imageSize.height
        let inner = box.insetBy(dx: box.width / 4, dy: box.height / 4)
        let x0 = max(Int(inner.minX * sx), 0), x1 = min(Int(inner.maxX * sx), depthWidth - 1)
        let y0 = max(Int(inner.minY * sy), 0), y1 = min(Int(inner.maxY * sy), depthHeight - 1)
        guard x0 <= x1, y0 <= y1 else { return nil }
        return (x0...x1, y0...y1)
    }

    /// Depth-map pixels around one point, such as a fingertip: `radius` depth pixels either side,
    /// clamped to the map. Nil when the point is outside the image.
    public static func window(around point: CGPoint, radius: Int, imageSize: CGSize, depthWidth: Int, depthHeight: Int)
        -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard imageSize.width > 0, imageSize.height > 0, depthWidth > 0, depthHeight > 0, radius >= 0,
              point.x >= 0, point.y >= 0, point.x < imageSize.width, point.y < imageSize.height else { return nil }
        let cx = Int(point.x * CGFloat(depthWidth) / imageSize.width)
        let cy = Int(point.y * CGFloat(depthHeight) / imageSize.height)
        return (max(cx - radius, 0)...min(cx + radius, depthWidth - 1),
                max(cy - radius, 0)...min(cy + radius, depthHeight - 1))
    }

    /// The nearest surface among the depths around a fingertip: their 20th percentile. A finger is
    /// in front of whatever is behind it, and the window around its tip also catches some of that
    /// background, so the median would read too far. Nil with fewer than `minimumCount` depths.
    public static func nearestSurface(_ depths: [Float], minimumCount: Int = 3) -> Double? {
        guard depths.count >= max(minimumCount, 1) else { return nil }
        let sorted = depths.sorted()
        return Double(sorted[sorted.count / 5])
    }

    /// The point seen at `point` (pixels of an image of `imageSize`, top left origin) at camera-plane
    /// depth `z`, in the pinhole camera's frame: x right, y down, z forward, in meters.
    public static func cameraPoint(planeDepth z: Double, at point: CGPoint, imageSize: CGSize,
                                   intrinsics k: CameraIntrinsics) -> SIMD3<Double> {
        guard k.fx > 0, k.fy > 0, imageSize.width > 0, imageSize.height > 0 else { return SIMD3(0, 0, z) }
        let u = Double(point.x * k.resolution.width / imageSize.width)
        let v = Double(point.y * k.resolution.height / imageSize.height)
        return SIMD3((u - k.cx) / k.fx * z, (v - k.cy) / k.fy * z, z)
    }

    /// A pinhole-frame point (x right, y down, z forward) in ARKit's camera frame (x right, y up,
    /// z toward the viewer), ready for `ARCamera.transform`.
    public static func arkitCameraPoint(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(p.x, -p.y, -p.z)
    }

    /// The median depth, the share of `considered` pixels that gave one, and the spread between
    /// the 25th and 75th percentiles. Nil with no depths.
    public static func summarize(_ depths: [Float], considered: Int)
        -> (median: Double, coverage: Double, spread: Double)? {
        guard !depths.isEmpty, considered > 0 else { return nil }
        let sorted = depths.sorted()
        let n = sorted.count
        let q1 = Double(sorted[n / 4]), q3 = Double(sorted[min(3 * n / 4, n - 1)])
        return (Double(sorted[n / 2]), Double(n) / Double(considered), q3 - q1)
    }

    /// Straight-line range to a point at camera-plane depth `z`. Depth is measured from the camera
    /// plane, so a product off the lens axis is farther than that, by the length of its ray
    /// through the image: sqrt(1 + ((u - cx) / fx)² + ((v - cy) / fy)²).
    /// - Parameter point: in the pixels of an image of `imageSize`, from its top left.
    public static func range(planeDepth z: Double, at point: CGPoint, imageSize: CGSize,
                             intrinsics k: CameraIntrinsics) -> Double {
        guard k.fx > 0, k.fy > 0, imageSize.width > 0, imageSize.height > 0 else { return z }
        // The intrinsics are for `k.resolution`; the image is the same one, checked anyway.
        let u = Double(point.x * k.resolution.width / imageSize.width)
        let v = Double(point.y * k.resolution.height / imageSize.height)
        return z * (1 + pow((u - k.cx) / k.fx, 2) + pow((v - k.cy) / k.fy, 2)).squareRoot()
    }

    /// A box in image pixels (top left origin) as Vision takes it: 0–1, bottom left origin, for
    /// the image as it is (orientation `.up`).
    public static func normalizedLowerLeft(_ box: CGRect, in imageSize: CGSize) -> CGRect {
        CGRect(x: box.minX / imageSize.width, y: 1 - box.maxY / imageSize.height,
               width: box.width / imageSize.width, height: box.height / imageSize.height)
    }

    /// The reverse of `normalizedLowerLeft(_:in:)`.
    public static func pixels(fromNormalizedLowerLeft rect: CGRect, in imageSize: CGSize) -> CGRect {
        CGRect(x: rect.minX * imageSize.width, y: (1 - rect.maxY) * imageSize.height,
               width: rect.width * imageSize.width, height: rect.height * imageSize.height)
    }
}
