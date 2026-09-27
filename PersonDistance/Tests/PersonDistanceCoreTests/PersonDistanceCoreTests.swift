import CoreGraphics
import XCTest
@testable import PersonDistanceCore

final class DepthGeometryTests: XCTestCase {
    /// ARKit's image and depth sizes on LiDAR iPhones.
    private let image = CGSize(width: 1920, height: 1440)

    func testWindowIsTheMiddleHalfOfTheBoxInDepthPixels() throws {
        let box = CGRect(x: 800, y: 600, width: 400, height: 240)
        let window = try XCTUnwrap(DepthGeometry.window(for: box, imageSize: image, depthWidth: 256, depthHeight: 192))
        // Middle half: x 900…1100, y 660…780; depth is 256/1920 = 0.1333 of the image.
        XCTAssertEqual(window.x, 120...146)
        XCTAssertEqual(window.y, 88...104)
    }

    func testWindowIsClampedToTheMap() throws {
        let box = CGRect(x: 1800, y: 1300, width: 400, height: 400)
        let window = try XCTUnwrap(DepthGeometry.window(for: box, imageSize: image, depthWidth: 256, depthHeight: 192))
        XCTAssertEqual(window.x.upperBound, 255)
        XCTAssertEqual(window.y.upperBound, 191)
    }

    func testWindowOutsideTheImageIsNil() {
        let box = CGRect(x: 3000, y: 100, width: 100, height: 100)
        XCTAssertNil(DepthGeometry.window(for: box, imageSize: image, depthWidth: 256, depthHeight: 192))
    }

    func testSummaryGivesMedianCoverageAndSpread() throws {
        let depths: [Float] = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7]
        let summary = try XCTUnwrap(DepthGeometry.summarize(depths, considered: 16))
        XCTAssertEqual(summary.median, 1.4, accuracy: 1e-6)
        XCTAssertEqual(summary.coverage, 0.5, accuracy: 1e-9)
        XCTAssertEqual(summary.spread, 1.6 - 1.2, accuracy: 1e-6)
    }

    func testSummaryOfNoDepthsIsNil() {
        XCTAssertNil(DepthGeometry.summarize([], considered: 10))
    }

    func testRangeOnTheLensAxisIsTheDepth() {
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, resolution: image)
        XCTAssertEqual(DepthGeometry.range(planeDepth: 1.0, at: CGPoint(x: 960, y: 720), imageSize: image, intrinsics: k),
                       1.0, accuracy: 1e-9)
    }

    func testRangeOffTheAxisIsLongerThanTheDepth() {
        // One focal length right of centre: the ray is at 45°, so range = depth × √2.
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, resolution: image)
        XCTAssertEqual(DepthGeometry.range(planeDepth: 1.0, at: CGPoint(x: 960 + 1500, y: 720), imageSize: image, intrinsics: k),
                       2.0.squareRoot(), accuracy: 1e-9)
    }

    func testRangeScalesThePointToTheIntrinsicsResolution() {
        // Intrinsics for an image twice the size: the same physical point.
        let k = CameraIntrinsics(fx: 3000, fy: 3000, cx: 1920, cy: 1440, resolution: CGSize(width: 3840, height: 2880))
        XCTAssertEqual(DepthGeometry.range(planeDepth: 1.0, at: CGPoint(x: 960 + 1500, y: 720), imageSize: image, intrinsics: k),
                       2.0.squareRoot(), accuracy: 1e-9)
    }

    func testVisionBoxHasItsOriginAtTheBottomLeft() {
        let box = CGRect(x: 0, y: 0, width: 960, height: 360)  // Top left quarter-width strip.
        let vision = DepthGeometry.normalizedLowerLeft(box, in: image)
        XCTAssertEqual(vision, CGRect(x: 0, y: 0.75, width: 0.5, height: 0.25))
    }

    func testVisionBoxConvertsBackToPixels() {
        let box = CGRect(x: 123, y: 456, width: 300, height: 200)
        let back = DepthGeometry.pixels(fromNormalizedLowerLeft: DepthGeometry.normalizedLowerLeft(box, in: image), in: image)
        XCTAssertEqual(back.minX, box.minX, accuracy: 1e-9)
        XCTAssertEqual(back.minY, box.minY, accuracy: 1e-9)
        XCTAssertEqual(back.width, box.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, box.height, accuracy: 1e-9)
    }
}

final class SpatialValidityPolicyTests: XCTestCase {
    private let policy = SpatialValidityPolicy()

    private func sample(coverage: Double = 0.8, spread: Double = 0.02, at time: TimeInterval = 10) -> DistanceSample {
        DistanceSample(meters: 1, coverage: coverage, spread: spread, frameTime: time)
    }

    func testAGoodReadingIsValid() {
        XCTAssertNil(policy.rejection(of: sample(), now: 10.1))
    }

    func testFewConfidentPixelsAreRejected() {
        XCTAssertEqual(policy.rejection(of: sample(coverage: 0.1), now: 10), .lowCoverage)
    }

    func testDisagreeingDepthsAreRejected() {
        XCTAssertEqual(policy.rejection(of: sample(spread: 0.3), now: 10), .uneven)
    }

    func testOldFramesAreRejected() {
        XCTAssertEqual(policy.rejection(of: sample(at: 10), now: 11), .stale)
    }
}

final class MeasurementGateTests: XCTestCase {
    private let milk = UUID(), bread = UUID()

    func testNothingIsMeasuredBeforeYes() {
        var gate = MeasurementGate()
        XCTAssertFalse(gate.isMeasuring)
        XCTAssertTrue(gate.confirmed(milk))
        XCTAssertEqual(gate.state, .following(milk))
        XCTAssertFalse(gate.isMeasuring)
    }

    func testYesStartsMeasuringTheFollowedItem() {
        var gate = MeasurementGate()
        _ = gate.confirmed(milk)
        XCTAssertTrue(gate.accepted(milk))
        XCTAssertEqual(gate.state, .measuring(milk))
    }

    func testYesWithoutAConfirmationMeasuresNothing() {
        var gate = MeasurementGate()
        XCTAssertFalse(gate.accepted(milk))
        XCTAssertEqual(gate.state, .idle)
    }

    func testYesForAnotherItemMeasuresNothing() {
        var gate = MeasurementGate()
        _ = gate.confirmed(bread)
        XCTAssertFalse(gate.accepted(milk))
        XCTAssertEqual(gate.state, .following(bread))
    }

    func testRepeatedConfirmationsDontRestart() {
        var gate = MeasurementGate()
        _ = gate.confirmed(milk)
        XCTAssertFalse(gate.confirmed(milk))
        _ = gate.accepted(milk)
        XCTAssertFalse(gate.confirmed(milk))
        XCTAssertEqual(gate.state, .measuring(milk))
    }

    func testTheNextItemReplacesTheMeasuredOne() {
        var gate = MeasurementGate()
        _ = gate.confirmed(milk)
        _ = gate.accepted(milk)
        XCTAssertTrue(gate.confirmed(bread))
        XCTAssertEqual(gate.state, .following(bread))
    }

    func testResetStopsEverything() {
        var gate = MeasurementGate()
        _ = gate.confirmed(milk)
        _ = gate.accepted(milk)
        gate.reset()
        XCTAssertEqual(gate.state, .idle)
        XCTAssertNil(gate.item)
    }
}

final class HandGeometryTests: XCTestCase {
    private let image = CGSize(width: 1920, height: 1440)

    func testWindowAroundAPointIsInDepthPixels() throws {
        // 7.5 image pixels per depth pixel: (960, 720) is depth pixel (128, 96).
        let window = try XCTUnwrap(DepthGeometry.window(around: CGPoint(x: 960, y: 720), radius: 2,
                                                        imageSize: image, depthWidth: 256, depthHeight: 192))
        XCTAssertEqual(window.x, 126...130)
        XCTAssertEqual(window.y, 94...98)
    }

    func testWindowAroundAPointIsClampedAtTheEdge() throws {
        let window = try XCTUnwrap(DepthGeometry.window(around: CGPoint(x: 1, y: 1), radius: 2,
                                                        imageSize: image, depthWidth: 256, depthHeight: 192))
        XCTAssertEqual(window.x, 0...2)
        XCTAssertEqual(window.y, 0...2)
    }

    func testWindowAroundAPointOutsideTheImageIsNil() {
        XCTAssertNil(DepthGeometry.window(around: CGPoint(x: 1920, y: 10), radius: 2,
                                          imageSize: image, depthWidth: 256, depthHeight: 192))
    }

    func testNearestSurfaceIgnoresTheBackgroundBehindAFinger() throws {
        // Three finger pixels at 0.60 m and six shelf pixels at 0.90 m.
        let depths: [Float] = [0.9, 0.6, 0.9, 0.9, 0.61, 0.9, 0.9, 0.6, 0.9]
        XCTAssertEqual(try XCTUnwrap(DepthGeometry.nearestSurface(depths)), 0.6, accuracy: 1e-6)
    }

    func testNearestSurfaceNeedsEnoughDepths() {
        XCTAssertNil(DepthGeometry.nearestSurface([0.6, 0.6]))
    }

    func testCameraPointAtTheOpticalCentreIsStraightAhead() {
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, resolution: image)
        XCTAssertEqual(DepthGeometry.cameraPoint(planeDepth: 0.8, at: CGPoint(x: 960, y: 720), imageSize: image, intrinsics: k),
                       SIMD3(0, 0, 0.8))
    }

    func testCameraPointRightAndBelowTheCentre() {
        // 300 px right and 150 px down at 1 m, focal length 1500 px: 0.2 m right, 0.1 m down.
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, resolution: image)
        let p = DepthGeometry.cameraPoint(planeDepth: 1, at: CGPoint(x: 1260, y: 870), imageSize: image, intrinsics: k)
        XCTAssertEqual(p.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(p.z, 1, accuracy: 1e-9)
    }

    func testARKitCameraFrameHasYUpAndZTowardTheViewer() {
        XCTAssertEqual(DepthGeometry.arkitCameraPoint(SIMD3(0.2, 0.1, 1)), SIMD3(0.2, -0.1, -1))
    }
}

final class HandReachPolicyTests: XCTestCase {
    private let policy = HandReachPolicy()

    private func sample(gap: Double, at time: TimeInterval = 5) -> HandSample {
        HandSample(meters: abs(gap), gap: gap, frameTime: time)
    }

    func testAtTheProductsDepthIsTouching() {
        XCTAssertEqual(policy.reach(sample(gap: 0.02), now: 5.1), .touching)
    }

    func testHoveringInFrontOfTheProductIsShort() {
        // Covers the product on screen, 15 cm in front of it: not "got it".
        XCTAssertEqual(policy.reach(sample(gap: 0.15), now: 5.1), .short)
    }

    func testAFingertipReadingBehindTheProductIsUnknown() {
        XCTAssertEqual(policy.reach(sample(gap: -0.2), now: 5.1), .unknown)
    }

    func testNoSampleOrAnOldOneIsUnknown() {
        XCTAssertEqual(policy.reach(nil, now: 5), .unknown)
        XCTAssertEqual(policy.reach(sample(gap: 0.01, at: 4), now: 5), .unknown)
    }
}
