import Foundation

/// What the tester puts in front of the camera and under what conditions. Declared
/// before the scan, so a trial's expected answer is fixed before any result is seen.
/// See `Baseline/README.md`.
public struct BaselineSetup: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// The selected item itself: success is being asked, then answering Yes.
        case target
        /// A near neighbor (Cool Ranch for Nacho Cheese, potato for onion): success is never being asked.
        case lookalike
        /// Anything else: another product, empty shelf, hand. Success is never being asked.
        case negative
        public var id: String { rawValue }
    }
    public enum Place: String, CaseIterable, Identifiable, Sendable { case store, home; public var id: String { rawValue } }
    public enum Light: String, CaseIterable, Identifiable, Sendable {
        case normal, dim, glare, backlit
        public var id: String { rawValue }
    }
    public enum Distance: String, CaseIterable, Identifiable, Sendable {
        case close = "close <30cm", arm = "arm 30-60cm", far = "far >60cm"
        public var id: String { rawValue }
    }
    public enum Motion: String, CaseIterable, Identifiable, Sendable {
        case still, walking
        public var id: String { rawValue }
    }

    public var kind: Kind = .target
    /// What is actually in view, in the tester's words: "Doritos Cool Ranch 9.25oz", "empty shelf".
    public var shown = ""
    public var place: Place = .store
    public var light: Light = .normal
    public var distance: Distance = .arm
    public var motion: Motion = .still
    public var notes = ""

    public init() {}
}

/// One scan attempt, attributed to pipeline stages. Apps create one per item scan, feed it every
/// update, and write it with `BaselineCSV.append` when the scan ends.
public struct BaselineTrial: Sendable {
    public enum Outcome: String, Sendable { case accepted, stopped, timedOut, error }

    public let setup: BaselineSetup
    public let targetTCIN: String
    public let targetTitle: String
    /// The grocery-list words the scan matched against.
    public let listEntry: String
    /// `ocr`, `appleVision` or `gemini`.
    public let path: String
    public let coverage: Double
    public let produceScore: Double
    /// Which app ran it: `demo` or `shellapp`.
    public let app: String
    /// How the scan started: `demo`, `walk` (at a stop on a real walk) or `testScan` (detection forced on).
    public let mode: String
    public let languageCorrection: Bool
    public let started: Date
    public private(set) var tally = RecognitionStageTally()
    public private(set) var asks = 0
    public var rejections = 0
    public private(set) var firstAsk: TimeInterval?
    public private(set) var askedLevel: RecognitionMatchLevel?
    public var timedOut = false
    public private(set) var maxMatch = 0
    public private(set) var maxScore = 0
    public private(set) var neighbors: [String: Int] = [:]
    public private(set) var lastRead = ""

    public init(setup: BaselineSetup, targetTCIN: String, targetTitle: String, listEntry: String, path: String,
                coverage: Double, produceScore: Double, app: String, mode: String,
                languageCorrection: Bool = true, started: Date = Date()) {
        self.setup = setup; self.targetTCIN = targetTCIN; self.targetTitle = targetTitle
        self.listEntry = listEntry; self.path = path; self.coverage = coverage; self.produceScore = produceScore
        self.app = app; self.mode = mode; self.languageCorrection = languageCorrection; self.started = started
    }

    /// `neighbor` is the title of another item that outscored the target on this frame, if any.
    public mutating func record(_ update: RecognitionUpdate, neighbor: String?) {
        if update.advanceNotice != nil { timedOut = true }
        guard let outcome = update.stageOutcome else { return }
        tally.record(outcome)
        if let result = update.result {
            maxMatch = max(maxMatch, Int((result.matchConfidence * 100).rounded()))
            maxScore = max(maxScore, Int((result.score * 100).rounded()))
        }
        if let neighbor { neighbors[neighbor, default: 0] += 1 }
        let read = update.observation?.candidates.map(\.rawText).joined(separator: " ")
            ?? update.result?.visualEvidence?.classifications.prefix(3)
                .map { "\($0.identifier)=\(Int(($0.score * 100).rounded()))%" }.joined(separator: " ")
        if let read, !read.isEmpty { lastRead = read }
    }

    public mutating func asked(_ level: RecognitionMatchLevel?, at now: Date = Date()) {
        asks += 1
        if firstAsk == nil { firstAsk = now.timeIntervalSince(started) }
        if askedLevel == nil { askedLevel = level }
    }

    /// A target trial succeeds when the shopper accepts; any other trial when it never asks.
    public func correct(_ outcome: Outcome) -> Bool {
        setup.kind == .target ? outcome == .accepted : asks == 0
    }

    public func row(_ outcome: Outcome, device: String, osVersion: String, now: Date = Date()) -> [String] {
        let counts = RecognitionStage.allCases.map { String(tally.stageCounts[$0] ?? 0) }
        let seconds = { (value: TimeInterval?) in value.map { String(format: "%.1f", $0) } ?? "" }
        return [
            ISO8601DateFormatter().string(from: started), device, osVersion,
            setup.place.rawValue, setup.light.rawValue, setup.distance.rawValue, setup.motion.rawValue,
            setup.kind.rawValue, targetTCIN, targetTitle,
            setup.shown.isEmpty && setup.kind == .target ? targetTitle : setup.shown, path,
            String(format: "%.2f", coverage), String(format: "%.2f", produceScore),
            outcome.rawValue, correct(outcome) ? "yes" : "no", String(asks), String(rejections),
            askedLevel?.rawValue ?? "", seconds(firstAsk), seconds(now.timeIntervalSince(started)),
            String(tally.frames), tally.furthest?.name ?? "", tally.blocker?.name ?? "",
        ] + counts + [
            tally.topReasons(3).map { "\($0.reason) \($0.count)" }.joined(separator: "; "),
            String(maxScore), String(maxMatch),
            neighbors.max { $0.value < $1.value }?.key ?? "", lastRead, setup.notes, listEntry,
            app, mode, VisionRevisions.summary, languageCorrection ? "on" : "off",
        ]
    }

    /// Columns up to `list_entry` are the original format; later ones are only appended, so
    /// `Baseline/summarize.py` reads old and new files alike.
    public static let header = [
        "started", "device", "ios", "place", "light", "distance", "motion",
        "kind", "target_tcin", "target_title", "shown", "path", "coverage_threshold", "produce_threshold",
        "outcome", "correct", "asks", "rejections", "asked_level", "seconds_to_first_ask", "seconds",
        "frames", "furthest_stage", "blocker",
    ] + RecognitionStage.allCases.map { "frames_" + $0.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_") }
      + ["top_reasons", "max_score_pct", "max_match_pct", "leading_neighbor", "last_read", "notes", "list_entry",
         "app", "trial_mode", "vision_revisions", "language_correction"]
}

/// The trials file: one CSV row per finished trial, header written with the first.
public enum BaselineCSV {
    /// Appends `trial` to the file at `url`, creating it with the header if needed.
    public static func append(_ trial: BaselineTrial, outcome: BaselineTrial.Outcome, to url: URL,
                              now: Date = Date()) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        var text = exists ? "" : line(BaselineTrial.header)
        text += line(trial.row(outcome, device: deviceModel, osVersion: osVersion, now: now))
        if exists {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    /// Trials saved in the file at `url`.
    public static func count(at url: URL) -> Int {
        max(0, ((try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 1) - 1)
    }

    /// The phone model id, e.g. `iPhone18,1`.
    public static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    /// "17.4.1", as the Settings app shows it.
    public static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    static func line(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",") + "\n"
    }
}
