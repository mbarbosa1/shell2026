import ARKit
import CoreGraphics
import Foundation
import ItemRecognition
import Observation
import PersonDistanceIOS

/// Runs the "find it on the shelf and help the user grab it" part of a stop, with `ItemScanner`:
///
/// 1. **Searching:** `AppModel` faces the arm to the item's shelf (`ArmController.face`) while
///    `ItemScanner` looks for it, and the cart is pushed along the shelf. PersonDistance starts
///    following the product when recognition asks "Is this Oat milk?".
/// 2. **Centering:** after Yes (`centerOnProduct()`), the arm turns in small steps toward the
///    product's box, which PersonDistance tracks on every check, until it's in the middle of the
///    frame, so it stays centered while the cart moves.
/// 3. **Guiding the hand:** PersonDistance keeps the product's place (`anchorProduct()`), the arm
///    holds still, and the watch plays `productFound`. A few times a second, `HandGuide` finds the
///    fingertip on screen and PersonDistance reads its depth: the watch buzzes left, right, up or
///    down until the hand is lined up, then "reach further" until it touches the product.
/// 4. **Done:** the fingertip has touched the product, in depth, for a moment. The watch plays
///    success and `onFinished(.pickedUp)` checks the item off.
///
/// If the product is lost while centering, `onFinished(.lost)`, and the item is looked for again.
/// Without a depth reading (no LiDAR, or none valid while centering), hand guiding falls back to
/// the screen alone (`isDepthGuided` is false), where covering the product counts as on it.
///
/// The arm stays still in step 3 on purpose: the hand covers the product, so computer vision
/// would lose it, and a moving phone would move the target the hand is aiming for.
///
/// Frames come from the app's one ARKit session (`CameraService`), so it only works while
/// shopping, when that session is running.
@MainActor
@Observable
final class PickupGuide {
    enum Phase: Equatable {
        case idle, centering, guidingHand, done
    }

    enum Outcome {
        /// The fingertip reached the product: it's in the shopper's hand.
        case pickedUp
        /// PersonDistance lost the product before the hand could be guided to it.
        case lost
    }

    private(set) var phase: Phase = .idle
    /// The latest hand advice, shown on the camera screen.
    private(set) var advice: HandGuide.Advice?
    /// True while hand guiding uses the fingertip's depth, false when it has only the screen.
    private(set) var isDepthGuided = false

    /// Set by `AppModel`: pickup of the item the shopper said Yes to is over.
    @ObservationIgnored var onFinished: (Outcome) -> Void = { _ in }

    /// Which way is up in ARKit's camera image: `.right` with the phone upright on the mount.
    /// Computer vision must use the same, so its boxes line up with the hand's position.
    static let frameOrientation = CGImagePropertyOrientation.right

    // MARK: Tuning

    /// Checks in a row with the product centered before the arm stops and hand guiding starts.
    private let centeredFramesNeeded = 3
    /// How often centering reads PersonDistance's box for the product (it tracks at the same rate).
    private let centerCheckInterval: Duration = .milliseconds(50)
    /// How long a centered product may go without a valid depth reading before hand guiding
    /// starts without depth.
    private let anchorWait: Duration = .seconds(3)
    /// Checks in a row with the same advice before the watch changes direction, so one jumpy
    /// frame doesn't flip the buzz back and forth.
    private let sameAdviceFramesNeeded = 2
    /// Checks in a row on the product before it counts as reached (~0.5 s).
    private let onItemFramesNeeded = 4
    /// With no hand in view this long, the watch stops buzzing an old direction.
    private let noHandTimeout: Duration = .seconds(2)
    /// How often the hand is checked. Vision takes ~20 ms per frame.
    private let handCheckInterval: Duration = .milliseconds(120)

    // MARK: State

    @ObservationIgnored private let arm: ArmController
    @ObservationIgnored private let watch: WatchLink
    @ObservationIgnored private let session: ARSession
    @ObservationIgnored private let range: ProductRangeSession
    @ObservationIgnored private let handGuide = HandGuide()
    @ObservationIgnored private let reachPolicy = HandReachPolicy()
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "shellapp.handguide")
    @ObservationIgnored private var centering: Task<Void, Never>?
    @ObservationIgnored private var handChecks: Task<Void, Never>?
    @ObservationIgnored private var candidate: HandGuide.Advice?
    @ObservationIgnored private var candidateFrames = 0
    @ObservationIgnored private var lastHandSeen = ContinuousClock.now
    /// The hand cue the watch is currently repeating, so it's only sent when it changes.
    @ObservationIgnored private var sentHaptic: WatchHaptic?

    init(arm: ArmController, watch: WatchLink, session: ARSession, range: ProductRangeSession) {
        self.arm = arm
        self.watch = watch
        self.session = session
        self.range = range
    }

    // MARK: Controls

    /// The shopper said Yes and PersonDistance is measuring the product: turn onto it, keep its
    /// place, and guide the hand to it.
    func centerOnProduct() {
        centering?.cancel()
        phase = .centering
        centering = Task {
            var centeredFrames = 0
            var centeredSince: ContinuousClock.Instant?
            while !Task.isCancelled && phase == .centering {
                guard range.status == .measuring else {
                    finish(.lost)
                    return
                }
                if let box = Self.visionBox(range.box, in: range.imageSize) {
                    centeredFrames = arm.center(on: box) ? 0 : centeredFrames + 1
                    if centeredFrames >= centeredFramesNeeded {
                        if range.anchorProduct(), let anchor = range.anchor,
                           let target = Self.visionBox(anchor.box, in: anchor.imageSize) {
                            startGuidingHand(target: target, usingDepth: true)
                            return
                        }
                        let since = centeredSince ?? .now
                        centeredSince = since
                        if ContinuousClock.now - since > anchorWait {
                            startGuidingHand(target: box, usingDepth: false)
                            return
                        }
                    }
                }
                try? await Task.sleep(for: centerCheckInterval)
            }
        }
    }

    /// Stops everything and turns off any hand-guide buzzing. PersonDistance is stopped by its
    /// owner (`ItemScanner`).
    func stop() {
        centering?.cancel()
        centering = nil
        handChecks?.cancel()
        handChecks = nil
        if phase == .guidingHand { watch.send(.handGuideOff, text: "Hand guide stopped.") }
        phase = .idle
        advice = nil
        isDepthGuided = false
    }

    #if DEBUG
    /// Tests hand guiding without recognition or depth: pretends the product is whatever is in the
    /// middle of the frame. Start shopping (so the camera runs), point the phone at something,
    /// and reach for it.
    func testHandGuide() {
        stop()
        startGuidingHand(target: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), usingDepth: false)
    }
    #endif

    // MARK: Hand guiding

    /// - Parameter target: the product in Vision coordinates (0–1, origin at the bottom left,
    ///   oriented like `frameOrientation`).
    private func startGuidingHand(target: CGRect, usingDepth: Bool) {
        centering?.cancel()
        centering = nil
        phase = .guidingHand
        isDepthGuided = usingDepth
        candidate = nil
        candidateFrames = 0
        sentHaptic = nil
        lastHandSeen = .now
        watch.send(.productFound, text: "Found it. Reach for it.")

        // Check the newest camera frame a few times a second until the hand reaches the target.
        handChecks = Task {
            while !Task.isCancelled && phase == .guidingHand {
                if let frame = session.currentFrame {
                    // The fingertip and its depth come from this one frame.
                    let snapshot = CameraSnapshot(frame)
                    let sighting = await look(in: snapshot.image, target: target)
                    if Task.isCancelled { return }
                    if let advice = decide(sighting, in: snapshot) { apply(advice) }
                }
                try? await Task.sleep(for: handCheckInterval)
            }
        }
    }

    /// Runs Vision off the main thread. Only the snapshot's buffers are kept, not the whole
    /// ARFrame, since holding frames stalls ARKit's camera.
    private func look(in image: CVPixelBuffer, target: CGRect) async -> HandGuide.Sighting {
        let handGuide = handGuide
        let orientation = Self.frameOrientation
        return await withCheckedContinuation { continuation in
            visionQueue.async {
                continuation.resume(returning: handGuide.look(in: image, orientation: orientation, productBox: target))
            }
        }
    }

    /// The screen's advice, checked against depth when there is some: over the product on screen
    /// isn't on it until the fingertip reaches the product's depth. Nil when this frame can't tell.
    private func decide(_ sighting: HandGuide.Sighting, in snapshot: CameraSnapshot) -> HandGuide.Advice? {
        guard sighting.advice == .onItem, isDepthGuided else { return sighting.advice }
        guard let tip = sighting.fingertip, let pixel = Self.imagePoint(tip, in: snapshot.imageSize) else { return nil }
        switch reachPolicy.reach(range.handSample(at: pixel, in: snapshot), now: snapshot.time) {
        case .touching: return .onItem
        case .short: return .reachFurther
        case .unknown: return nil
        }
    }

    private func apply(_ advice: HandGuide.Advice) {
        guard phase == .guidingHand else { return }

        if advice == .noHand {
            // The hand left the frame for a while: stop buzzing a direction that's now stale.
            if sentHaptic != nil, ContinuousClock.now - lastHandSeen > noHandTimeout {
                sentHaptic = nil
                self.advice = .noHand
                watch.send(.handGuideOff, text: "Reach toward the shelf.")
            }
            return
        }
        lastHandSeen = .now

        if advice == candidate {
            candidateFrames += 1
        } else {
            candidate = advice
            candidateFrames = 1
        }
        let needed = advice == .onItem ? onItemFramesNeeded : sameAdviceFramesNeeded
        guard candidateFrames >= needed else { return }
        self.advice = advice

        if advice == .onItem {
            phase = .done
            handChecks?.cancel()
            handChecks = nil
            watch.send(.handOnItem, text: "Got it.")
            onFinished(.pickedUp)
            return
        }
        let haptic = advice.watchHaptic
        guard haptic != sentHaptic else { return }
        sentHaptic = haptic
        watch.send(haptic, text: Self.text(for: advice))
    }

    private func finish(_ outcome: Outcome) {
        stop()
        onFinished(outcome)
    }

    /// What the watch screen shows with each hand cue.
    private static func text(for advice: HandGuide.Advice) -> String {
        switch advice {
        case .left: "Hand left"
        case .right: "Hand right"
        case .up: "Hand up"
        case .down: "Hand down"
        case .reachFurther: "Reach further"
        case .onItem: "Got it."
        case .noHand: "Reach toward the shelf."
        }
    }

    // MARK: Coordinates

    /// PersonDistance's box (camera image pixels, top left) in Vision coordinates for
    /// `frameOrientation`, which the arm and HandGuide use.
    static func visionBox(_ box: CGRect?, in size: CGSize?) -> CGRect? {
        guard let box, let size else { return nil }
        let inside = box.intersection(CGRect(origin: .zero, size: size))
        guard !inside.isNull else { return nil }
        return try? VisionRegionOfInterest.normalized(pixelCrop: inside, imageSize: size, orientation: frameOrientation)
    }

    /// A Vision point (0–1, bottom left, oriented like `frameOrientation`) in camera image pixels
    /// from the top left, which PersonDistance takes.
    private static func imagePoint(_ point: CGPoint, in size: CGSize) -> CGPoint? {
        let side = 0.002
        let spot = CGRect(x: min(max(point.x - side / 2, 0), 1 - side), y: min(max(point.y - side / 2, 0), 1 - side),
                          width: side, height: side)
        guard let pixels = try? VisionRegionOfInterest.pixelCrop(normalizedRegion: spot, imageSize: size,
                                                                 orientation: frameOrientation) else { return nil }
        return CGPoint(x: pixels.midX, y: pixels.midY)
    }
}
