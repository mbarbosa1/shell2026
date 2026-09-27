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
/// While it looks, `PickupGuide` sweeps the arm across the stop's shelves. Once the camera settles
/// on the item, the arm holds and the user is asked "Is this Oat milk?". No keeps looking. Yes
/// starts PersonDistance measuring it, and pickup turns the arm onto it and guides the hand; the
/// item goes in the cart (`found`) once the fingertip reaches it (user decision, September 27,
/// 2026). While looking, a hint like "Move more to the left" is said when it changes, at most every
/// `hintInterval`. Everything goes out through `announce`: spoken, and played on the watch.
@MainActor
@Observable
final class ItemScanner {
    /// The item being looked for.
    private(set) var target: ScanTarget?
    /// "Is this Oat milk?" while waiting for a yes or no.
    private(set) var question: String?
    /// The latest hint, e.g. "Move closer to the item". Nil when there's nothing to fix.
    private(set) var hint: String?
    /// The item the user said Yes to while pickup guides their hand to it. Recognition is over
    /// for it; it goes in the cart when pickup finishes.
    private(set) var pickingUp: ScanTarget?
    private(set) var diagnostics = ScanDiagnostics()
    private(set) var isTestScan = false

    /// How far past the end of a stop's lane the camera keeps looking.
    static let margin = 1.5
    static let hintInterval: TimeInterval = 4

    /// Says a line and plays its watch cue. Set by `AppModel`.
    @ObservationIgnored var announce: (String, WatchHaptic?) -> Void = { _, _ in }
    /// Puts the list item with this id in the cart. Set by `AppModel`.
    @ObservationIgnored var found: (UUID) -> Void = { _ in }
    /// PersonDistance: follows the product asked about, and measures its distance once the shopper
    /// says Yes (never before). Set by `AppModel`.
    @ObservationIgnored var range: ProductRangeSession?
    /// Sweeps the arm while looking and guides the hand after a Yes. Set by `AppModel`.
    @ObservationIgnored var pickup: PickupGuide?
    /// Baseline trials in tester mode: every item scan is one. It also holds the OCR language
    /// correction setting the next item uses. Set by `AppModel`.
    @ObservationIgnored var trials: TrialRecorder?
    /// A real walk, or a tester's test scan (which never touches the list).
    @ObservationIgnored private var mode = TrialRecorder.Mode.walk
    @ObservationIgnored private var queue: [ScanTarget] = []
    /// Which side of the user the stop's shelves are on, for the arm's sweep. Empty for a test scan,
    /// where the tester points the camera.
    @ObservationIgnored private var sides: [ArmController.ShelfSide] = []
    /// Meters past the reference node, or nil before it; and whether tracking can be trusted.
    @ObservationIgnored private var progress: () -> (meters: Double?, reliable: Bool) = { (nil, false) }
    @ObservationIgnored private var coordinator: RecognitionCoordinator?
    @ObservationIgnored private var produceClassifier: ProduceCategoryClassifier?
    @ObservationIgnored private var latestFrameTime: TimeInterval?
    @ObservationIgnored private var answering = false
    /// Bumped for every new target, so work for an old one is dropped.
    @ObservationIgnored private var run = 0
    /// A frame is being looked at. Frames that arrive meanwhile are dropped (see `PositionTracker.onFrame`).
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var spokenHint: String?
    @ObservationIgnored private var spokenAt: TimeInterval = -.infinity
    @ObservationIgnored private var toldToMoveOn = false

    /// Starts looking for `targets`: at the stop just reached on a walk, or right away for a test scan.
    /// - Parameter sides: where the stop's shelves are, for the arm's sweep. None: no sweep.
    func begin(_ targets: [ScanTarget], sides: [ArmController.ShelfSide] = [], mode: TrialRecorder.Mode = .walk,
               progress: @escaping () -> (meters: Double?, reliable: Bool)) {
        queue = targets
        self.sides = sides
        self.mode = mode
        isTestScan = mode == .testScan
        self.progress = progress
        next(announcing: false)
    }

    /// Tester bar: saves the trial in progress and stops looking for this item until `restartTarget()`.
    func stopTrial() {
        stopTarget()
        diagnostics.status = "Stopped · last results retained"
        diagnostics.note("Trial stopped")
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
        isTestScan = false
    }

    /// Call when the list changes. Moves on when the item being looked for is in the cart or gone.
    func listChanged(remaining: Set<UUID>) {
        queue.removeAll { !remaining.contains($0.listItemID) }
        guard let target, !remaining.contains(target.listItemID) else { return }
        next(announcing: true)
    }

    /// The user's answer to `question`.
    func answer(_ yes: Bool) {
        guard !answering, question != nil, let target, let coordinator else { return }
        // Test scans validate the actual receipt before reporting success, and do
        // not enter the shopping arm/hand-pickup flow.
        if isTestScan && yes {
            answering = true
            let run = run
            Task {
                let receipt = await coordinator.acceptInsight()
                guard run == self.run else { return }
                answering = false
                guard let receipt else {
                    question = nil
                    diagnostics.error = "This suggestion expired. Start a new trial before validating."
                    diagnostics.note("Acceptance failed: no recognition receipt")
                    return
                }
                trials?.finish(.accepted)
                stopTarget()
                diagnostics.receipt = receipt
                diagnostics.status = "Scan validated"
                diagnostics.note("Validated by shopper · \(receipt.matchLevel.rawValue)")
                announce("Scan validated for \(target.name).", nil)
            }
            return
        }
        question = nil
        if yes {
            trials?.finish(.accepted)
            range?.measure(target.listItemID)
            Task { await coordinator.acceptInsight() }
            if let pickup, range?.status == .measuring {
                // In the cart once the hand reaches it (`pickupFinished`), not now.
                pickingUp = target
                pickup.centerOnProduct()
            } else {
                // Nothing to guide the hand to: no single product box, or no LiDAR.
                picked(target)
            }
        } else {
            answering = true
            run += 1 // Drop a pending settled update from before the user's No.
            let run = run
            diagnostics.note("Shopper rejected suggestion; looking again")
            trials?.rejected()
            range?.stop()
            pickup?.resumeSearch()
            Task {
                await coordinator.rejectInsight()
                guard run == self.run else { return }
                answering = false
                diagnostics.latest = nil
                diagnostics.status = "Scanning"
            }
            announce("Okay, still looking for \(target.name).", nil)
        }
    }

    /// `PickupGuide` finished with the item the user said Yes to. Lost: look for it again.
    func pickupFinished(_ outcome: PickupGuide.Outcome) {
        guard let target, pickingUp?.listItemID == target.listItemID else { return }
        pickingUp = nil
        switch outcome {
        case .pickedUp:
            picked(target)
        case .lost:
            announce("Lost \(target.name). Looking again.", nil)
            queue.insert(target, at: 0)
            next(announcing: false)
        }
    }

    /// A camera image from ARKit. The phone is mounted upright, so ARKit's landscape image is turned
    /// a quarter turn right. Frames taken while the lens refocuses aren't counted as evidence.
    func receive(_ buffer: CVPixelBuffer, at time: TimeInterval, isAdjustingFocus: Bool) {
        latestFrameTime = time
        if trials?.isEnabled == true, diagnostics.isRunning {
            diagnostics.receivedFrames += 1
            diagnostics.lastFrameAt = Date()
            if busy { diagnostics.busyFrames += 1 }
        }
        // During pickup recognition is over for the item: its coordinator stopped at the Yes.
        guard !busy, !answering, pickingUp == nil, let coordinator, let target else { return }
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
            let started = Date()
            let update: RecognitionUpdate
            do {
                update = try await coordinator.submit(context, image: image)
            } catch {
                print("📷 Recognition failed for \(target.name): \(error.localizedDescription)")
                if run == self.run {
                    diagnostics.error = error.localizedDescription
                    diagnostics.status = "Recognition error"
                    diagnostics.note("Error: \(error.localizedDescription)")
                    trials?.finish(.error)
                }
                return
            }
            guard run == self.run else { return }
            if trials?.isEnabled == true {
                diagnostics.record(update, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
            handle(update, at: time, imageSize: size)
        }
    }

    // MARK: Private

    private func next(announcing: Bool) {
        stopTarget()
        guard !queue.isEmpty else {
            target = nil
            return
        }
        let target = queue.removeFirst()
        self.target = target
        diagnostics = ScanDiagnostics()
        diagnostics.status = "Starting recognition"
        diagnostics.cloudConfigured = target.catalog.recognizesByAppearance && CloudAssistConfig.endpoint != nil
        diagnostics.cloudEndpoint = CloudAssistConfig.endpoint?.host
        latestFrameTime = nil
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
                produceClassifier = classifier
                diagnostics.isRunning = true
                diagnostics.status = "Waiting for camera frames"
                diagnostics.note(target.catalog.recognizesByAppearance ? "Apple Vision · appearance scan" : "OCR · label scan")
                if classifier != nil && !diagnostics.cloudConfigured {
                    diagnostics.note("Gemini unavailable: configure the proxy in test settings")
                }
                trials?.begin(target, mode: mode)
                pickup?.search(sides: sides)
            } catch {
                print("📷 Can't look for \(target.name): \(error.localizedDescription)")
                guard run == self.run else { return }
                diagnostics.error = error.localizedDescription
                diagnostics.status = "Could not start recognition"
                diagnostics.note("Setup failed: \(error.localizedDescription)")
                if !isTestScan { next(announcing: true) }
            }
        }
    }

    /// Polled by the tester UI so an in-flight cloud request is visible while
    /// camera submissions are busy. Generation checking drops old scan results.
    func refreshCloudUsage() async {
        guard let produceClassifier else { return }
        let run = run
        let usage = await produceClassifier.usage(at: latestFrameTime)
        guard run == self.run else { return }
        let previous = diagnostics.cloud
        diagnostics.cloud = usage
        if usage.isRequestInFlight && previous?.isRequestInFlight != true {
            diagnostics.note("Gemini request \(usage.calls)/\(usage.limit) in progress")
        }
        if let failure = usage.lastFailure, failure != previous?.lastFailure {
            diagnostics.note("Gemini failed: \(failure)")
        }
        if let label = usage.lastLabel, label != previous?.lastLabel {
            diagnostics.note("Gemini returned \(label.label) · \(Int(label.confidence * 100))%")
        }
    }

    /// The title of another product that outscored the target on this frame, for trial records.
    private func neighbor(in update: RecognitionUpdate) -> String? {
        guard let target, let id = update.result?.leadingItemID ?? update.result?.matchedItemID,
              id != target.catalog.targetID else { return nil }
        return target.catalog.candidates.first { $0.id == id }?.displayName
    }

    /// The item is in the user's hand: into the cart. A test scan only measures recognition, so
    /// the list stays as it is.
    private func picked(_ target: ScanTarget) {
        if mode == .testScan { stopTarget() } else { found(target.listItemID) }
    }

    private func stopTarget() {
        // Leaving the item any way but Yes: after the one-minute notice it counts as timed out.
        trials?.finish(.stopped)
        run += 1
        if let coordinator { Task { await coordinator.stop() } }
        coordinator = nil
        produceClassifier = nil
        answering = false
        diagnostics.isRunning = false
        question = nil
        hint = nil
        pickingUp = nil
        // Done with this item's product: LiDAR off, arm and hand guide stopped.
        range?.stop()
        pickup?.stop()
        spokenHint = nil
        spokenAt = -.infinity
        toldToMoveOn = false
    }

    private func handle(_ update: RecognitionUpdate, at time: TimeInterval, imageSize: CGSize) {
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
            pickup?.hold()
            follow(update, imageSize: imageSize)
            announce(prompt, .arrived)
            return
        }
        // The item half-seen: keep the arm still so recognition can make sure.
        if let result = update.result, result.status == .candidate, result.matchedItemID == target?.catalog.targetID {
            pickup?.holdBriefly()
        }
        // After a minute at the item without finding it.
        if let notice = update.advanceNotice, !toldToMoveOn {
            toldToMoveOn = true
            hint = nil
            announce(notice, nil)
        }
        // Frames that weren't looked at (in between, or detection off) carry no result.
        guard update.gate.isDetectionActive, update.result != nil else {
            if !update.gate.isDetectionActive { hint = nil }
            return
        }
        hint = update.framingInstruction
        guard let hint, hint != spokenHint, time - spokenAt >= Self.hintInterval else {
            if hint == nil { spokenHint = nil }
            return
        }
        spokenHint = hint
        spokenAt = time
        announce(hint, update.guidance?.haptic)
    }

    /// Hands the product being asked about to PersonDistance to follow until the answer. Only one
    /// product: the one whose text matched when several were in view, or the only one in view,
    /// never the region around several. With neither, a Yes has nothing to measure.
    private func follow(_ update: RecognitionUpdate, imageSize: CGSize) {
        guard !isTestScan else { return }
        let objects = update.assessment?.objectBoxes.count ?? 0
        guard let target,
              let box = update.focusedObject ?? (objects == 1 ? update.assessment?.objectRegion : nil) else { return }
        range?.follow(target.listItemID, box: box, imageSize: imageSize)
    }
}

private extension RecognitionGuidance {
    /// Left and right are taps on the watch, like turns.
    var haptic: WatchHaptic? {
        switch self {
        case .moveLeft: .left
        case .moveRight: .right
        default: nil
        }
    }
}
