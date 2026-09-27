import ARKit
import CoreImage
import Foundation
import ItemRecognition
import Observation
import PersonDistanceIOS

/// Finds the self-checkout machines at the end of the trip and guides the shopper to them (user
/// decision, September 27, 2026). `RouteNavigator` starts it when the last leg, along the map's
/// self-checkout row, begins:
///
/// 1. **Looking:** the arm looks ahead and to the machines' side (`ArmController.lookoutPoses`), and
///    every frame checked goes to Gemini first, and to Apple Vision when Gemini can't answer
///    (`SelfCheckoutFinder`).
/// 2. **Guiding:** once one is seen, PersonDistance follows and measures it straight away (no Yes:
///    the shopper can't be asked "Is this the self checkout?"), the arm keeps it in view, and its
///    distance is spoken when it changes: "Self checkout on your right, about 3 meters."
/// 3. **Reached:** at `reachedMeters` or closer, `onReached` ends the trip.
///
/// If PersonDistance loses it, looking starts again. Each frame checked is copied small first, so
/// ARKit's camera buffer isn't held for the seconds a Gemini call takes.
@MainActor
@Observable
final class CheckoutFinder {
    enum Phase: Equatable {
        case idle, looking, guiding, reached
    }

    private(set) var phase = Phase.idle
    /// The latest sighting, for testers: where it came from and what gave it away.
    private(set) var sighting: SelfCheckoutSighting?
    /// Why Gemini didn't answer the latest frame, for testers. Nil when it did.
    private(set) var cloudProblem: String?

    /// Says a line and plays its watch cue. Set by `AppModel`.
    @ObservationIgnored var announce: (String, WatchHaptic?) -> Void = { _, _ in }
    /// The first sighting of this search.
    @ObservationIgnored var onSighted: () -> Void = {}
    /// The cart is at the machine.
    @ObservationIgnored var onReached: () -> Void = {}

    /// Camera-to-machine meters that count as there. A draft for the bench test (PersonDistance README).
    static let reachedMeters = 1.5
    /// Sightings less sure than this are ignored.
    static let minimumConfidence: Float = 0.5
    /// What PersonDistance measures the self checkout as: it isn't a list item.
    static let checkoutID = UUID()
    /// Frames are scaled down to this long side before they're checked: enough for Gemini (the
    /// proxy is sent at most 768 px) and for sign text.
    static let frameLongSide: CGFloat = 960

    private let lookInterval: Duration = .milliseconds(700)
    /// How long the arm holds each lookout pose.
    private let sweepDwell: Duration = .milliseconds(1500)
    /// How often a changed distance may be spoken.
    private let distanceInterval: Duration = .seconds(4)

    @ObservationIgnored private let arm: ArmController
    @ObservationIgnored private let session: ARSession
    @ObservationIgnored private let range: ProductRangeSession
    @ObservationIgnored private let imageContext = CIContext()
    @ObservationIgnored private var finder: SelfCheckoutFinder?
    @ObservationIgnored private var side = StoreMap.Side.right
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private var sweep: Task<Void, Never>?
    @ObservationIgnored private var spokenMeters: Double?
    @ObservationIgnored private var spokenAt = ContinuousClock.now
    @ObservationIgnored private var hasSighted = false

    init(arm: ArmController, session: ARSession, range: ProductRangeSession) {
        self.arm = arm
        self.session = session
        self.range = range
    }

    /// Starts looking along the row. The machines are on `side`.
    func start(side: StoreMap.Side) {
        stop()
        self.side = side
        // Read now, so a proxy set in the tester settings since launch is used.
        finder = SelfCheckoutFinder(cloud: CloudAssistConfig.checkoutLocator())
        hasSighted = false
        startLooking()
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                if self.phase == .reached { return }
                try? await Task.sleep(for: self.lookInterval)
            }
        }
    }

    /// Stops looking and guiding, and PersonDistance's measuring of the machine.
    func stop() {
        looking?.cancel()
        looking = nil
        sweep?.cancel()
        sweep = nil
        if range.item == Self.checkoutID { range.stop() }
        phase = .idle
        sighting = nil
        cloudProblem = nil
        finder = nil
    }

    // MARK: Private

    private var sideWord: String { side == .left ? "left" : "right" }

    private func startLooking() {
        phase = .looking
        sighting = nil
        let poses = arm.lookoutPoses(facing: side)
        sweep?.cancel()
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                for pose in poses {
                    guard let self else { return }
                    self.arm.move(to: pose)
                    try? await Task.sleep(for: self.sweepDwell)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func step() async {
        switch phase {
        case .looking: await look()
        case .guiding: guide()
        case .idle, .reached: break
        }
    }

    private func look() async {
        guard let finder, let frame = session.currentFrame, let small = smallCopy(of: frame) else { return }
        let attempt = await finder.locate(small.image)
        guard phase == .looking, !Task.isCancelled else { return }
        cloudProblem = attempt.cloudProblem
        guard let found = attempt.sighting, found.confidence >= Self.minimumConfidence else { return }
        sighting = found
        sweep?.cancel()
        sweep = nil
        // PersonDistance takes the camera image's own pixels.
        let box = found.box.applying(CGAffineTransform(scaleX: small.scale, y: small.scale))
        range.measureNow(Self.checkoutID, box: box, imageSize: small.cameraSize)
        phase = .guiding
        spokenMeters = nil
        spokenAt = .now
        announce("Self checkout on your \(sideWord).", nil)
        if !hasSighted {
            hasSighted = true
            onSighted()
        }
    }

    private func guide() {
        switch range.status {
        case .measuring:
            break
        case .noDepth:
            // No LiDAR, so no distance: the end of the row ends the trip.
            return
        default:
            // Lost it: look again.
            startLooking()
            return
        }
        if let box = PickupGuide.visionBox(range.box, in: range.imageSize) { arm.center(on: box) }
        guard let meters = range.sample?.meters else { return }
        if meters <= Self.reachedMeters {
            phase = .reached
            range.stop()
            arm.moveHome()
            onReached()
            return
        }
        let rounded = (meters * 2).rounded() / 2
        guard spokenMeters.map({ abs($0 - rounded) >= 1 }) ?? true,
              ContinuousClock.now - spokenAt >= distanceInterval else { return }
        spokenMeters = rounded
        spokenAt = .now
        let figure = rounded.formatted(.number.precision(.fractionLength(0...1)))
        announce("Self checkout on your \(sideWord), about \(figure) meters.", nil)
    }

    /// A small copy of the frame's camera image, so ARKit's buffer goes back at once, and the scale
    /// from the copy's pixels to the camera image's.
    private func smallCopy(of frame: ARFrame) -> (image: RecognitionImage, scale: CGFloat, cameraSize: CGSize)? {
        let source = frame.capturedImage
        let cameraSize = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let factor = min(1, Self.frameLongSide / max(cameraSize.width, cameraSize.height))
        let width = Int((cameraSize.width * factor).rounded()), height = Int((cameraSize.height * factor).rounded())
        var copy: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard width > 0, height > 0,
              CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &copy)
                == kCVReturnSuccess, let copy else { return nil }
        let scaled = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / cameraSize.width, y: CGFloat(height) / cameraSize.height))
        imageContext.render(scaled, to: copy)
        let image = RecognitionImage(timestamp: frame.timestamp, pixelBuffer: copy,
                                     imageResolution: CGSize(width: width, height: height),
                                     orientation: PickupGuide.frameOrientation)
        return (image, cameraSize.width / CGFloat(width), cameraSize)
    }
}
