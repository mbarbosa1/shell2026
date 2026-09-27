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
/// Once the camera settles on the item, the user is asked "Is this Oat milk?". Yes puts it in the
/// cart (`found`), no keeps looking. While looking, a hint like "Move more to the left" is said when
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
    /// Measures `objectMeters`. Set by `AppModel`.
    @ObservationIgnored var depth: ProductDepthEstimator?
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

    /// Starts looking for `targets` at the stop just reached.
    func begin(_ targets: [ScanTarget], progress: @escaping () -> (meters: Double?, reliable: Bool)) {
        queue = targets
        self.progress = progress
        next(announcing: false)
    }

    /// The user left the stop, or shopping ended.
    func end() {
        queue = []
        progress = { (nil, false) }
        stopTarget()
        target = nil
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
            Task { await coordinator.acceptInsight() }
            found(target.listItemID)
        } else {
            Task { await coordinator.rejectInsight() }
            announce("Okay, still looking for \(target.name).", nil)
        }
    }

    /// A camera image from ARKit. The phone is mounted upright, so ARKit's landscape image is turned
    /// a quarter turn right.
    func receive(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        guard !busy, let coordinator, let target else { return }
        let (meters, reliable) = progress()
        let context = RecognitionContext(
            targetItemID: target.catalog.targetID,
            landmarkProgress: LandmarkProgressObservation(
                timestamp: time, passedLandmarkID: meters == nil ? nil : target.catalog.rule.landmarkID,
                metersPastLandmark: meters, isReliable: reliable),
            externalPause: false)
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let image = RecognitionImage(timestamp: time, pixelBuffer: buffer, imageResolution: size, orientation: .right)
        busy = true
        let run = run
        Task {
            defer { busy = false }
            let update: RecognitionUpdate
            do {
                update = try await coordinator.submit(context, image: image)
            } catch {
                print("📷 Recognition failed for \(target.name): \(error.localizedDescription)")
                return
            }
            guard run == self.run else { return }
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
        // The navigator already named the stop's items on arrival.
        if announcing { announce("Now looking for \(target.name).", nil) }
        let run = run
        Task {
            do {
                let classifier = target.catalog.recognizesByAppearance ? try ProduceCategoryClassifier() : nil
                let coordinator = try await RecognitionCoordinator(
                    targetID: target.catalog.targetID, catalog: target.catalog,
                    visualClassifier: classifier, visualPolicy: .appleVisionProduce, query: target.query)
                guard run == self.run else {
                    await coordinator.stop()
                    return
                }
                self.coordinator = coordinator
            } catch {
                print("📷 Can't look for \(target.name): \(error.localizedDescription)")
                guard run == self.run else { return }
                next(announcing: true)
            }
        }
    }

    private func stopTarget() {
        run += 1
        if let coordinator { Task { await coordinator.stop() } }
        coordinator = nil
        question = nil
        hint = nil
        objectMeters = nil
        spokenHint = nil
        spokenAt = -.infinity
        toldToMoveOn = false
    }

    private func handle(_ update: RecognitionUpdate, at time: TimeInterval, imageSize: CGSize) {
        if update.awaitingVerdict {
            guard question == nil, let prompt = update.verdictPrompt else { return }
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
        hint = update.guidance?.message
        guard let guidance = update.guidance, hint != spokenHint, time - spokenAt >= Self.hintInterval else {
            if hint == nil { spokenHint = nil }
            return
        }
        spokenHint = hint
        spokenAt = time
        announce(guidance.message, guidance.haptic)
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
