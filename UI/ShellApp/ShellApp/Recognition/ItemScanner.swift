import CoreVideo
import Foundation
import ItemRecognition
import Observation
import PersonDistanceIOS

/// Looks for the list's items with the camera while the user is at a stop.
///
/// A stop begins at its reference node: `RouteNavigator` reports reaching it, and `begin` gets the
/// stop's items. Detection is on from there to the end of the stop's lane (`ScanTarget`'s window),
/// by the meters `progress` reports, and off everywhere else, so no frame is looked at on the way
/// to a stop. Items are looked for one at a time, in the order given.
///
/// Once the camera settles on the item, the user is asked "Is this Oat milk?". Yes hands it to the
/// arm and hand guide (`pickUp`) when they're set up, and it goes in the cart (`found`) once the
/// hand reaches it; otherwise yes puts it straight in the cart. No keeps looking. While looking, a hint like "Move more to the left" is said when
/// it changes, at most every `hintInterval`. Everything goes out through `announce`: spoken, and
/// played on the watch.
@MainActor
@Observable
final class ItemScanner {
    /// The item being looked for.
    private(set) var target: ScanTarget?
    /// "Is this Oat milk?" while waiting for a yes or no.
    private(set) var question: String?
    /// The latest hint, e.g. "Move closer to the item". Nil when there's nothing to fix.
    private(set) var hint: String?
    /// Meters from the phone to the product in view, from PersonDistance, for the camera screen.
    /// Nil with no single product in view or no reading. Only shown; nothing is decided by it.
    private(set) var objectMeters: Double?

    /// How far past the end of a stop's lane the camera keeps looking.
    static let margin = 1.5
    static let hintInterval: TimeInterval = 4

    /// Says a line and plays its watch cue. Set by `AppModel`.
    @ObservationIgnored var announce: (String, WatchHaptic?) -> Void = { _, _ in }
    /// Puts the list item with this id in the cart. Set by `AppModel`.
    @ObservationIgnored var found: (UUID) -> Void = { _ in }
    /// Called with each new item looked for, and nil when there's none, so the arm can turn to
    /// its shelf. Set by `AppModel`.
    @ObservationIgnored var targetChanged: (ScanTarget?) -> Void = { _ in }
    /// Which way the arm points the camera. Turned to a side, left and right in the image are
    /// ahead and behind along the shelf, so those hints tell the user to push or pull the cart.
    /// Set by `AppModel`.
    @ObservationIgnored var facing = StoreMap.Side.ahead
    /// Hands the confirmed item to the arm and hand guide (`PickupGuide.track`), with where it is in
    /// the frame. The scanner pauses until `pickUpEnded`. Set by `AppModel`.
    @ObservationIgnored var pickUp: ((CGRect) -> Void)?
    /// Measures `objectMeters`. Set by `AppModel`.
    @ObservationIgnored var depth: ProductDepthEstimator?
    /// Baseline trials in tester mode: every item scan is one. It also holds the OCR language
    /// correction setting the next item uses. Set by `AppModel`.
    @ObservationIgnored var trials: TrialRecorder?
    /// A real walk, or a tester's test scan (which never touches the list).
    @ObservationIgnored private var mode = TrialRecorder.Mode.walk
    @ObservationIgnored private var queue: [ScanTarget] = []
    /// Meters past the reference node, or nil before it; and whether tracking can be trusted.
    @ObservationIgnored private var progress: () -> (meters: Double?, reliable: Bool) = { (nil, false) }
    @ObservationIgnored private var coordinator: RecognitionCoordinator?
    /// Bumped for every new target, so work for an old one is dropped.
    @ObservationIgnored private var run = 0
    /// A frame is being looked at. Frames that arrive meanwhile are dropped (see `PositionTracker.onFrame`).
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var spokenHint: String?
    @ObservationIgnored private var spokenAt: TimeInterval = -.infinity
    @ObservationIgnored private var toldToMoveOn = false
    /// Where the item was last seen in the frame, in Vision coordinates (0–1, origin at the bottom
    /// left, in the upright image), for `pickUp`.
    @ObservationIgnored private var productBox: CGRect?
    /// Between a yes and `pickUpEnded`: the hand guide has the camera, so frames aren't looked at.
    @ObservationIgnored private var isPickingUp = false

    /// Starts looking for `targets`: at the stop just reached on a walk, or right away for a test scan.
    func begin(_ targets: [ScanTarget], mode: TrialRecorder.Mode = .walk,
               progress: @escaping () -> (meters: Double?, reliable: Bool)) {
        queue = targets
        self.mode = mode
        self.progress = progress
        next(announcing: false)
    }

    /// Tester bar: saves the trial in progress and stops looking for this item until `restartTarget()`.
    func stopTrial() {
        stopTarget()
    }

    /// Tester bar: looks for the same item again, as a new trial.
    func restartTarget() {
        guard let target else { return }
        queue.insert(target, at: 0)
        next(announcing: false)
    }

    /// The user left the stop, or shopping ended.
    func end() {
        queue = []
        progress = { (nil, false) }
        stopTarget()
        target = nil
        targetChanged(nil)
    }

    /// Call when the list changes. Moves on when the item being looked for is in the cart or gone.
    func listChanged(remaining: Set<UUID>) {
        queue.removeAll { !remaining.contains($0.listItemID) }
        guard let target, !remaining.contains(target.listItemID) else { return }
        next(announcing: true)
    }

    /// The user's answer to `question`.
    func answer(_ yes: Bool) {
        guard question != nil, let target, let coordinator else { return }
        question = nil
        if yes {
            trials?.finish(.accepted)
            Task { await coordinator.acceptInsight() }
            if let pickUp, let productBox {
                isPickingUp = true
                hint = nil
                pickUp(productBox)
            } else {
                finish(target)
            }
        } else {
            trials?.rejected()
            Task { await coordinator.rejectInsight() }
            announce("Okay, still looking for \(target.name).", nil)
        }
    }

    /// The hand guide is done with the item `pickUp` handed it: the hand reached it, or the arm
    /// lost it first and it's looked for again.
    func pickUpEnded(reached: Bool) {
        guard isPickingUp, let target else { return }
        isPickingUp = false
        if reached {
            finish(target)
        } else {
            announce("Lost \(target.name). Looking again.", nil)
            queue.insert(target, at: 0)
            next(announcing: false)
        }
    }

    /// A camera image from ARKit. The phone is mounted upright, so ARKit's landscape image is turned
    /// a quarter turn right. Frames taken while the lens refocuses aren't counted as evidence.
    func receive(_ buffer: CVPixelBuffer, at time: TimeInterval, isAdjustingFocus: Bool) {
        guard !busy, !isPickingUp, let coordinator, let target else { return }
        let (meters, reliable) = progress()
        let context = RecognitionContext(
            targetItemID: target.catalog.targetID,
            landmarkProgress: LandmarkProgressObservation(
                timestamp: time, passedLandmarkID: meters == nil ? nil : target.catalog.rule.landmarkID,
                metersPastLandmark: meters, isReliable: reliable),
            externalPause: false)
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let image = RecognitionImage(timestamp: time, pixelBuffer: buffer, imageResolution: size, orientation: .right,
                                     isAdjustingFocus: isAdjustingFocus)
        busy = true
        let run = run
        Task {
            defer { busy = false }
            let update: RecognitionUpdate
            do {
                update = try await coordinator.submit(context, image: image)
            } catch {
                print("📷 Recognition failed for \(target.name): \(error.localizedDescription)")
                if run == self.run { trials?.finish(.error) }
                return
            }
            guard run == self.run else { return }
            handle(update, at: time, imageSize: size)
        }
    }

    // MARK: Private

    /// The item is found. A test scan only measures recognition; the list stays as it is.
    private func finish(_ target: ScanTarget) {
        if mode == .testScan { stopTarget() } else { found(target.listItemID) }
    }

    private func next(announcing: Bool) {
        stopTarget()
        guard !queue.isEmpty else {
            target = nil
            targetChanged(nil)
            return
        }
        let target = queue.removeFirst()
        self.target = target
        targetChanged(target)
        // The navigator already named the stop's items on arrival.
        if announcing { announce("Now looking for \(target.name).", nil) }
        let run = run
        let correction = trials?.usesLanguageCorrection ?? true
        Task {
            do {
                // Produce: Apple Vision first, then Gemini when a proxy is set (CloudAssistConfig).
                let classifier = target.catalog.recognizesByAppearance
                    ? try ProduceCategoryClassifier(cloud: CloudAssistConfig.labeler()) : nil
                let coordinator = try await RecognitionCoordinator(
                    targetID: target.catalog.targetID, catalog: target.catalog,
                    recognizer: VisionTextRecognizer(usesLanguageCorrection: correction),
                    visualClassifier: classifier, visualPolicy: .appleVisionProduce, query: target.query)
                guard run == self.run else {
                    await coordinator.stop()
                    return
                }
                self.coordinator = coordinator
                trials?.begin(target, mode: mode)
            } catch {
                print("📷 Can't look for \(target.name): \(error.localizedDescription)")
                guard run == self.run else { return }
                next(announcing: true)
            }
        }
    }

    /// The title of another product that outscored the target on this frame, for trial records.
    private func neighbor(in update: RecognitionUpdate) -> String? {
        guard let target, let id = update.result?.leadingItemID ?? update.result?.matchedItemID,
              id != target.catalog.targetID else { return nil }
        return target.catalog.candidates.first { $0.id == id }?.displayName
    }

    private func stopTarget() {
        // Leaving the item any way but Yes: after the one-minute notice it counts as timed out.
        trials?.finish(.stopped)
        run += 1
        if let coordinator { Task { await coordinator.stop() } }
        coordinator = nil
        question = nil
        hint = nil
        objectMeters = nil
        spokenHint = nil
        spokenAt = -.infinity
        toldToMoveOn = false
        productBox = nil
        isPickingUp = false
    }

    /// Where the item is in the frame, in Vision coordinates: the one object in view, or with
    /// several, the one the catalog picked. Nil when there's no telling.
    private static func productBox(in update: RecognitionUpdate, imageSize: CGSize) -> CGRect? {
        let boxes = update.assessment?.objectBoxes ?? []
        guard boxes.count > 1 else { return boxes.first }
        guard let focused = update.focusedObject else { return nil }
        // `focusedObject` is in the camera buffer's pixels: pick the box that crops to it.
        func overlap(_ box: CGRect) -> CGFloat {
            guard let crop = try? VisionRegionOfInterest.pixelCrop(
                normalizedRegion: box, imageSize: imageSize, orientation: .right) else { return 0 }
            let common = crop.intersection(focused)
            return common.isNull ? 0 : common.width * common.height
        }
        return boxes.max { overlap($0) < overlap($1) }
    }

    private func handle(_ update: RecognitionUpdate, at time: TimeInterval, imageSize: CGSize) {
        if let box = Self.productBox(in: update, imageSize: imageSize) { productBox = box }
        // A settled answer repeats on every frame until answered: one question, one recorded frame.
        if update.awaitingVerdict && question != nil {
            if update.advanceNotice != nil { trials?.timedOut() }
        } else {
            trials?.record(update, neighbor: neighbor(in: update))
        }
        if update.awaitingVerdict {
            guard question == nil, let prompt = update.verdictPrompt else { return }
            trials?.asked(update.result?.matchLevel)
            question = prompt
            hint = nil
            announce(prompt, .arrived)
            return
        }
        // After a minute at the item without finding it.
        if let notice = update.advanceNotice, !toldToMoveOn {
            toldToMoveOn = true
            announce(notice, nil)
        }
        // Frames that weren't looked at (in between, or detection off) carry no result.
        guard update.gate.isDetectionActive, update.result != nil else {
            if !update.gate.isDetectionActive {
                hint = nil
                objectMeters = nil
            }
            return
        }
        objectMeters = depth?.range(
            focused: update.focusedObject, region: update.assessment?.objectRegion,
            objectCount: update.assessment?.objectBoxes.count ?? 0, imageSize: imageSize)
        hint = update.guidance.map { $0.message(facing: facing) }
        guard let guidance = update.guidance, hint != spokenHint, time - spokenAt >= Self.hintInterval else {
            if hint == nil { spokenHint = nil }
            return
        }
        spokenHint = hint
        spokenAt = time
        announce(guidance.message(facing: facing), guidance.haptic(facing: facing))
    }
}

private extension RecognitionGuidance {
    /// Which way along the shelf "left" and "right" in the image are, with the camera turned to
    /// `side`: facing right, the image's left is ahead of the cart; facing left, it's behind.
    /// Nil for any other hint, or with the camera facing ahead.
    private func along(facing side: StoreMap.Side) -> Bool? {
        switch (self, side) {
        case (.moveLeft, .right), (.moveRight, .left): true
        case (.moveLeft, .left), (.moveRight, .right): false
        default: nil
        }
    }

    func message(facing side: StoreMap.Side) -> String {
        switch along(facing: side) {
        case true?: "Push the cart forward a little"
        case false?: "Pull the cart back a little"
        case nil: message
        }
    }

    /// Left and right are taps on the watch, like turns. Forward along the shelf is the "go" cue;
    /// back has none, so only the words say it.
    func haptic(facing side: StoreMap.Side) -> WatchHaptic? {
        switch along(facing: side) {
        case true?: return .go
        case false?: return nil
        case nil: break
        }
        switch self {
        case .moveLeft: return .left
        case .moveRight: return .right
        default: return nil
        }
    }
}
