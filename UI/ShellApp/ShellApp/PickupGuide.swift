import ARKit
import CoreGraphics
import Foundation
import Observation

/// Runs the "find it on the shelf and help the user grab it" part of a stop, in four phases:
///
/// 1. **Searching:** the arm sweeps the phone across the shelf (`ArmController.sweepPoses`) while
///    computer vision looks for the product. The vision code reports what it sees by calling
///    `productSeen(_:)`.
/// 2. **Centering:** the arm turns in small steps until the product is in the middle of the frame.
/// 3. **Guiding the hand:** the arm holds still and the watch plays `productFound`. A few times a
///    second, `HandGuide` finds the user's hand in the camera frame and the watch buzzes which way
///    to move it.
/// 4. **Done:** the fingertip has stayed on the product for a moment, and the watch plays success.
///
/// The arm stays still in phase 3 on purpose: the hand covers the product, so computer vision
/// would lose it, and a moving phone would move the target the hand is aiming for. Computer vision
/// should pause while `phase == .guidingHand`.
///
/// Frames come from the app's one ARKit session (`CameraService`), so it only works while
/// shopping, when that session is running.
@MainActor
@Observable
final class PickupGuide {
    enum Phase: Equatable {
        case idle, searching, centering, guidingHand, done
        /// The sweep finished without computer vision seeing the product.
        case notFound
    }

    private(set) var phase: Phase = .idle
    /// The latest hand advice, shown on the camera screen.
    private(set) var advice: HandGuide.Advice?

    /// Which way is up in ARKit's camera image: `.right` with the phone upright on the mount.
    /// Computer vision must use the same, so its boxes line up with the hand's position.
    static let frameOrientation = CGImagePropertyOrientation.right

    // MARK: Tuning

    /// Frames in a row with the product centered before the arm stops and hand guiding starts.
    private let centeredFramesNeeded = 3
    /// Checks in a row with the same advice before the watch changes direction, so one jumpy
    /// frame doesn't flip the buzz back and forth.
    private let sameAdviceFramesNeeded = 2
    /// Checks in a row on the product before it counts as reached (~0.5 s).
    private let onItemFramesNeeded = 4
    /// With no hand in view this long, the watch stops buzzing an old direction.
    private let noHandTimeout: Duration = .seconds(2)
    /// How long the arm holds each sweep pose, so computer vision gets a few frames there.
    private let sweepDwell: Duration = .milliseconds(1200)
    private let sweepPasses = 2
    /// How often the hand is checked. Vision takes ~20 ms per frame.
    private let handCheckInterval: Duration = .milliseconds(120)

    // MARK: State

    @ObservationIgnored private let arm: ArmController
    @ObservationIgnored private let watch: WatchLink
    @ObservationIgnored private let session: ARSession
    @ObservationIgnored private let handGuide = HandGuide()
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "shellapp.handguide")
    @ObservationIgnored private var sweep: Task<Void, Never>?
    @ObservationIgnored private var handChecks: Task<Void, Never>?
    @ObservationIgnored private var centeredFrames = 0
    @ObservationIgnored private var candidate: HandGuide.Advice?
    @ObservationIgnored private var candidateFrames = 0
    @ObservationIgnored private var lastHandSeen = ContinuousClock.now
    /// The hand cue the watch is currently repeating, so it's only sent when it changes.
    @ObservationIgnored private var sentHaptic: WatchHaptic?

    init(arm: ArmController, watch: WatchLink, session: ARSession) {
        self.arm = arm
        self.watch = watch
        self.session = session
    }

    // MARK: Controls

    /// Starts searching the shelf on one side, e.g. from the map's `Visit.side` for this item.
    func start(shelfSide: ArmController.ShelfSide) {
        stop()
        phase = .searching
        let poses = arm.sweepPoses(facing: shelfSide)
        sweep = Task {
            for _ in 0..<sweepPasses {
                for pose in poses {
                    arm.move(to: pose)
                    try? await Task.sleep(for: sweepDwell)
                    if Task.isCancelled { return }
                }
            }
            phase = .notFound
            arm.moveHome()
        }
    }

    /// Stops everything and turns off any hand-guide buzzing.
    func stop() {
        sweep?.cancel()
        sweep = nil
        handChecks?.cancel()
        handChecks = nil
        if phase == .guidingHand { watch.send(.handGuideOff, text: "Hand guide stopped.") }
        phase = .idle
        advice = nil
    }

    #if DEBUG
    /// Tests hand guiding without computer vision: pretends the product is whatever is in the
    /// middle of the frame. Start shopping (so the camera runs), point the phone at something,
    /// and reach for it.
    func testHandGuide() {
        stop()
        startGuidingHand(target: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
    }
    #endif

    // MARK: Input from computer vision

    /// Called by the computer vision code with the product's box (Vision coordinates: 0–1, origin
    /// at the bottom left, oriented like `frameOrientation`), or nil when it isn't in view.
    func productSeen(_ box: CGRect?) {
        guard let box else { return }  // Out of view: keep sweeping, or hold the last step.
        switch phase {
        case .searching:
            sweep?.cancel()
            sweep = nil
            phase = .centering
            centeredFrames = 0
            center(on: box)
        case .centering:
            center(on: box)
        default:
            break
        }
    }

    private func center(on box: CGRect) {
        let moved = arm.center(on: box)
        centeredFrames = moved ? 0 : centeredFrames + 1
        guard centeredFrames >= centeredFramesNeeded else { return }
        startGuidingHand(target: box)
    }

    // MARK: Hand guiding

    private func startGuidingHand(target: CGRect) {
        phase = .guidingHand
        candidate = nil
        candidateFrames = 0
        sentHaptic = nil
        lastHandSeen = .now
        watch.send(.productFound, text: "Found it. Reach for it.")

        // Check the newest camera frame a few times a second until the hand reaches the target.
        handChecks = Task {
            while !Task.isCancelled && phase == .guidingHand {
                if let frame = session.currentFrame?.capturedImage {
                    let advice = await checkHand(in: frame, target: target)
                    if Task.isCancelled { return }
                    apply(advice)
                }
                try? await Task.sleep(for: handCheckInterval)
            }
        }
    }

    /// Runs Vision off the main thread. Only the pixel buffer is kept, not the whole ARFrame,
    /// since holding frames stalls ARKit's camera.
    private func checkHand(in frame: CVPixelBuffer, target: CGRect) async -> HandGuide.Advice {
        let handGuide = handGuide
        let orientation = Self.frameOrientation
        return await withCheckedContinuation { continuation in
            visionQueue.async {
                continuation.resume(returning: handGuide.advice(for: frame, orientation: orientation, productBox: target))
            }
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
            return
        }
        let haptic = advice.watchHaptic
        guard haptic != sentHaptic else { return }
        sentHaptic = haptic
        watch.send(haptic, text: Self.text(for: advice))
    }

    /// What the watch screen shows with each hand cue.
    private static func text(for advice: HandGuide.Advice) -> String {
        switch advice {
        case .left: "Hand left"
        case .right: "Hand right"
        case .up: "Hand up"
        case .down: "Hand down"
        case .onItem: "Got it."
        case .noHand: "Reach toward the shelf."
        }
    }
}
