import CoreGraphics
import Foundation

/// A self-checkout machine seen in a camera frame, so the app can guide the shopper to it after the
/// last item (ShellApp's `CheckoutFinder`; PersonDistance measures how far it is).
public struct SelfCheckoutSighting: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Gemini, through `ItemRecognition/CloudProxy` (`/v1/self-checkout`).
        case cloud(model: String)
        /// Apple Vision's text and labels (`VisionSelfCheckoutLocator`).
        case appleVision
    }

    /// Where it is, in the frame's stored-buffer pixels from the top left, like
    /// `RecognitionUpdate.focusedObject`.
    public let box: CGRect
    /// Self-reported by Gemini, or a fixed draft for Apple Vision's evidence. Not calibrated.
    public let confidence: Float
    public let source: Source
    /// What gave it away, for testers: "Gemini" or "Read “SELF CHECKOUT”".
    public let evidence: String

    public init(box: CGRect, confidence: Float, source: Source, evidence: String) {
        self.box = box
        self.confidence = confidence
        self.source = source
        self.evidence = evidence
    }
}

/// Looks for a self-checkout machine in one camera frame.
public protocol SelfCheckoutLocating: Sendable {
    /// Nil when the frame shows none. Throws when it couldn't tell (network, model, bad image).
    func locate(_ image: RecognitionImage) async throws -> SelfCheckoutSighting?
}

/// Gemini first, Apple Vision when Gemini isn't set up or doesn't answer (user decision,
/// September 27, 2026: the cloud is primary for the self-checkout). After a failed Gemini call,
/// Apple Vision works alone for `cloudRetryAfter` seconds of camera time, so an unreachable proxy
/// doesn't add its timeout to every frame.
public actor SelfCheckoutFinder {
    public struct Attempt: Sendable, Equatable {
        public let sighting: SelfCheckoutSighting?
        /// True when Gemini answered this frame, found or not.
        public let usedCloud: Bool
        /// Why Gemini didn't answer, when it didn't: not set up, paused after a failure, or its error.
        public let cloudProblem: String?
    }

    public static let cloudRetryAfter: TimeInterval = 10

    private let cloud: (any SelfCheckoutLocating)?
    private let onDevice: any SelfCheckoutLocating
    /// Camera time (`RecognitionImage.timestamp`) before which Gemini isn't asked again.
    private var cloudPausedUntil: TimeInterval?
    private var lastCloudProblem: String?

    /// - Parameters:
    ///   - cloud: the Gemini proxy client, or nil when no proxy is set up.
    ///   - onDevice: the fallback.
    public init(cloud: (any SelfCheckoutLocating)?, onDevice: any SelfCheckoutLocating = VisionSelfCheckoutLocator()) {
        self.cloud = cloud
        self.onDevice = onDevice
    }

    public func locate(_ image: RecognitionImage) async -> Attempt {
        var problem = cloud == nil ? "Gemini proxy not set" : nil
        if let cloud {
            if let until = cloudPausedUntil, image.timestamp < until {
                problem = lastCloudProblem
            } else {
                do {
                    let sighting = try await cloud.locate(image)
                    cloudPausedUntil = nil
                    return Attempt(sighting: sighting, usedCloud: true, cloudProblem: nil)
                } catch {
                    cloudPausedUntil = image.timestamp + Self.cloudRetryAfter
                    lastCloudProblem = error.localizedDescription
                    problem = lastCloudProblem
                }
            }
        }
        let sighting = (try? await onDevice.locate(image)) ?? nil
        return Attempt(sighting: sighting, usedCloud: false, cloudProblem: problem)
    }
}

// MARK: - Apple Vision fallback

/// What Apple Vision can say about a self-checkout. Its classifier's 1,303 labels have no
/// self-checkout, register or kiosk, so text on signs and screens decides, and the nearest labels
/// only back up text that isn't specific enough on its own.
public enum SelfCheckoutEvidence {
    /// Text that names a self-checkout: enough on its own.
    public static let namingPhrases = ["self checkout", "self check out", "selfcheckout",
                                       "self serve checkout", "self service checkout"]
    /// Text that self-checkout screens show: only with a supporting label.
    public static let screenPhrases = ["scan your first item", "scan your items", "touch to start", "tap to start",
                                       "touch screen to start", "start scanning", "place item in bag",
                                       "place items in bag", "bagging area"]
    /// The classifier labels nearest to a self-checkout machine.
    public static let supportingLabels: Set<String> = ["atm", "computer_monitor", "machine"]
    public static let minimumTextConfidence: Float = 0.3
    public static let minimumLabelScore: Float = 0.2
    /// Drafts, not calibrated: naming text is strong, screen text with a label weaker.
    public static let namingConfidence: Float = 0.8
    public static let screenConfidence: Float = 0.6

    /// The text lines that show a self-checkout, how sure that is, and what they read. Nil when
    /// the frame doesn't show one.
    public static func decide(lines: [RecognizedTextLine], labels: [VisualClassification])
        -> (lines: [RecognizedTextLine], confidence: Float, evidence: String)? {
        let readable = lines.filter { $0.confidence >= minimumTextConfidence }
        func matching(_ phrases: [String]) -> [RecognizedTextLine] {
            readable.filter { line in
                let words = " \(normalize(line.text)) "
                return phrases.contains { words.contains(" \($0) ") }
            }
        }
        let naming = matching(namingPhrases)
        if let first = naming.first {
            return (naming, namingConfidence, "Read “\(first.text)”")
        }
        let screen = matching(screenPhrases)
        let support = labels.filter { supportingLabels.contains($0.identifier) && $0.score >= minimumLabelScore }
            .max { $0.score < $1.score }
        if let first = screen.first, let support {
            return (screen, screenConfidence, "Read “\(first.text)”, looks like \(support.identifier)")
        }
        return nil
    }

    /// Lowercase letters and digits, one space between words: "SELF-CHECKOUT" → "self checkout".
    public static func normalize(_ text: String) -> String {
        let spaced = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }
}

/// Apple Vision's self-checkout locator: OCR of the whole frame plus the image classifier, both
/// at the revisions pinned in `VisionRevisions`.
public struct VisionSelfCheckoutLocator: SelfCheckoutLocating {
    private let text: VisionTextRecognizer
    private let classifier: VisionImageClassifier

    public init(text: VisionTextRecognizer = VisionTextRecognizer(), classifier: VisionImageClassifier = VisionImageClassifier()) {
        self.text = text
        self.classifier = classifier
    }

    public func locate(_ image: RecognitionImage) async throws -> SelfCheckoutSighting? {
        let lines = try await text.recognizeText(in: image, regionOfInterest: nil)
        let labels = try await classifier.classify(in: image, crop: nil).classifications
        guard let decision = SelfCheckoutEvidence.decide(lines: lines, labels: labels),
              let first = decision.lines.first else { return nil }
        // The text's lines, together: a sign, or the screen of the machine.
        let region = decision.lines.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let box = try VisionRegionOfInterest.pixelCrop(normalizedRegion: region, imageSize: image.imageResolution,
                                                        orientation: image.orientation)
        return SelfCheckoutSighting(box: box, confidence: decision.confidence, source: .appleVision,
                                    evidence: decision.evidence)
    }
}
