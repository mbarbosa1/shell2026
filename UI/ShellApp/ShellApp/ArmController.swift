import CoreGraphics
import Foundation
import Observation

/// Points the phone by sending angles to the 3 servos on the cart (see `firmware/src/main.cpp`):
/// - **pan** (GPIO 4) turns the phone left and right.
/// - **tilt1** (GPIO 5) and **tilt2** (GPIO 6) sit on the two sides of the phone clamp and tilt it
///   up and down together. They're one joint driven from both sides, so they must always move as
///   a pair: `move(to:)` sets tilt1 from tilt2, and nothing else ever sets tilt1.
///
/// Every angle is clamped to the ranges below, which are tighter than the firmware's own
/// 20–160° limits. The firmware also smooths each move (`MAX_STEP`), so even a big jump
/// turns the phone gradually instead of jerking it.
@MainActor
@Observable
final class ArmController {
    /// Where the phone points. `tilt` is tilt2's angle; tilt1 follows it (see `tiltMirrored`).
    struct Pose: Equatable {
        var pan: Int
        var tilt: Int
    }

    // MARK: Calibrate these on the real arm

    /// Pan angle with the phone facing straight ahead. Every "Ahead" goes back to exactly this
    /// angle. Above 90, because the pan servo runs out of travel below about 45: the holder is
    /// seated on the servo facing straight at this angle, so both sides have room.
    static let panAhead = 110
    /// How far "left" and "right" turn from `panAhead`, the same amount both ways. Make it
    /// negative if left and right come out swapped.
    static let panToSide = 45
    /// Phone facing straight ahead, level.
    static let home = Pose(pan: panAhead, tilt: 90)
    /// Pan angles that face the shelf on the user's left and right.
    static let panFacingLeft = panAhead + panToSide
    static let panFacingRight = panAhead - panToSide
    /// Keep `panAhead ± panToSide` inside this, or one side gets cut short and they're uneven.
    static let panRange = 25...155
    static let tiltRange = 60...120
    /// True when the two tilt servos face each other, so tilting up means one angle goes up and
    /// the other goes down (tilt1 = 180 - tilt2). False when they turn the same way (tilt1 = tilt2).
    /// Check with the Serial Monitor test: whichever setting tilts the clamp without twisting it.
    static let tiltMirrored = true
    /// Flip to -1 if centering turns the phone away from the product instead of toward it.
    static let panDirection = 1.0
    static let tiltDirection = 1.0

    // MARK: Centering

    /// The camera's field of view in degrees (iPhone main camera, phone upright). Turns
    /// "the product is 20% of the frame right of center" into "turn about 10° right".
    static let horizontalFOV = 50.0
    static let verticalFOV = 65.0
    /// Within this distance from the center (as a fraction of the frame), the arm stays still,
    /// so it doesn't twitch back and forth around the product.
    static let deadZone = 0.08
    /// Only turn this fraction of the way per step, so the arm doesn't overshoot while the
    /// camera catches up with where it now points.
    static let gain = 0.5
    /// The most one step may turn. Small steps are slower but keep the stand steady.
    static let maxStepDegrees = 3.0

    @ObservationIgnored private let cart: CartBluetooth
    /// The last pose sent.
    private(set) var pose = home
    /// The latest moves, newest first, for the debug panel: why, and the angles each servo was
    /// sent.
    private(set) var recentMoves: [String] = []

    init(cart: CartBluetooth) {
        self.cart = cart
    }

    /// Sends a pose, clamped to the safe ranges, with both tilt servos set from `tilt`. `why` is
    /// shown in the debug panel's list of moves.
    func move(to target: Pose, why: String = "move") {
        let safe = Pose(
            pan: min(max(target.pan, Self.panRange.lowerBound), Self.panRange.upperBound),
            tilt: min(max(target.tilt, Self.tiltRange.lowerBound), Self.tiltRange.upperBound)
        )
        pose = safe
        let tilt1 = Self.tiltMirrored ? 180 - safe.tilt : safe.tilt
        cart.sendArm(pan: UInt8(safe.pan), tilt1: UInt8(tilt1), tilt2: UInt8(safe.tilt))

        let limited = safe != target ? " (limited)" : ""
        recentMoves.insert("\(why): pan \(safe.pan) · tilt1 \(tilt1) · tilt2 \(safe.tilt)\(limited)", at: 0)
        if recentMoves.count > 5 { recentMoves.removeLast() }
    }

    func moveHome() {
        move(to: Self.home, why: "home")
    }

    /// Turns the phone to a shelf, level, for scanning it while the cart moves. Nil (no side on
    /// the map) faces straight ahead.
    func face(_ side: StoreMap.Side?) {
        let side = side ?? .ahead
        move(to: Pose(pan: Self.pan(facing: side), tilt: Self.home.tilt), why: "face \(side.rawValue)")
    }

    /// Debug panel: turns a few degrees from wherever the arm is, to find the pan angle that
    /// faces straight ahead (`panAhead`).
    func nudgePan(by degrees: Int) {
        move(to: Pose(pan: pose.pan + degrees, tilt: pose.tilt), why: "nudge")
    }

    /// Debug panel: tilts a few degrees from wherever the arm is. Both tilt servos move, as always.
    /// A higher tilt angle is meant to be up; if the panel's "Tilt up" tilts down, that's reversed.
    func nudgeTilt(by degrees: Int) {
        move(to: Pose(pan: pose.pan, tilt: pose.tilt + degrees), why: "tilt")
    }

    /// Debug panel: back to level without turning.
    func level() {
        move(to: Pose(pan: pose.pan, tilt: Self.home.tilt), why: "level")
    }

    /// Where to look while searching one side's shelf: three pan angles across the shelf,
    /// each at eye level, higher, and lower, so a whole section gets seen.
    func sweepPoses(facing side: StoreMap.Side) -> [Pose] {
        let middle = Self.pan(facing: side)
        return [-20, 0, 20].flatMap { panOffset in
            [90, 70, 110].map { tilt in Pose(pan: middle + panOffset, tilt: tilt) }
        }
    }

    /// Turns one small step toward `box`, the product's position in the frame in Vision
    /// coordinates (0–1, origin at the bottom left).
    ///
    /// Returns false when it didn't move: the product is centered, or the arm is already at its
    /// limit and can't turn further. Either way, that's as centered as it gets.
    @discardableResult
    func center(on box: CGRect) -> Bool {
        // Positive = the product is right of / above the center.
        let panStep = Self.step(offset: box.midX - 0.5, fieldOfView: Self.horizontalFOV) * Self.panDirection
        let tiltStep = Self.step(offset: box.midY - 0.5, fieldOfView: Self.verticalFOV) * Self.tiltDirection

        var next = pose
        next.pan += Int(panStep.rounded(.awayFromZero))
        next.tilt += Int(tiltStep.rounded(.awayFromZero))
        let before = pose
        move(to: next, why: "center")
        return pose != before
    }

    private static func pan(facing side: StoreMap.Side) -> Int {
        switch side {
        case .left: panFacingLeft
        case .right: panFacingRight
        case .ahead: home.pan
        }
    }

    /// Degrees to turn for a product `offset` (-0.5…0.5) from the center. 0 inside the dead zone.
    private static func step(offset: Double, fieldOfView: Double) -> Double {
        guard abs(offset) > deadZone else { return 0 }
        let degrees = offset * fieldOfView * gain
        return min(max(degrees, -maxStepDegrees), maxStepDegrees)
    }
}
