import XCTest
@testable import ItemRecognition

final class BaselineTrialTests: XCTestCase {
    private func trial(kind: BaselineSetup.Kind = .target) -> BaselineTrial {
        var setup = BaselineSetup()
        setup.kind = kind
        setup.notes = "shelf \"B\", top row"
        return BaselineTrial(setup: setup, targetTCIN: "13276204", targetTitle: "2% Reduced Fat Milk - 1gal",
                             listEntry: "2% milk", path: "ocr", coverage: 0.65, produceScore: 0.3,
                             app: "shellapp", mode: "testScan", languageCorrection: false,
                             started: Date(timeIntervalSince1970: 0))
    }

    func testRowHasOneFieldPerHeaderColumnAndEndsWithTheNewColumns() {
        let row = trial().row(.accepted, device: "iPhone18,1", osVersion: "27.0", now: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(row.count, BaselineTrial.header.count)
        XCTAssertEqual(Array(BaselineTrial.header.suffix(4)), ["app", "trial_mode", "vision_revisions", "language_correction"])
        XCTAssertEqual(Array(row.suffix(4)), ["shellapp", "testScan", VisionRevisions.summary, "off"])
        XCTAssertEqual(row[BaselineTrial.header.firstIndex(of: "seconds")!], "12.0")
    }

    func testCorrectnessByKind() {
        var asked = trial(kind: .lookalike)
        XCTAssertTrue(asked.correct(.stopped))
        asked.asked(.product)
        XCTAssertFalse(asked.correct(.stopped))
        XCTAssertTrue(trial().correct(.accepted))
        XCTAssertFalse(trial().correct(.timedOut))
    }

    func testAppendWritesHeaderOnceAndQuotesFields() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "trials-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try BaselineCSV.append(trial(), outcome: .accepted, to: url)
        try BaselineCSV.append(trial(), outcome: .stopped, to: url)
        XCTAssertEqual(BaselineCSV.count(at: url), 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(BaselineTrial.header.joined(separator: ",") + "\n"))
        XCTAssertTrue(text.contains("\"shelf \"\"B\"\", top row\""))
    }
}
