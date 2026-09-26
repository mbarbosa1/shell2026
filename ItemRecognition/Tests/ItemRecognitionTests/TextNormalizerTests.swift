import XCTest
@testable import ItemRecognition

final class TextNormalizerTests: XCTestCase {
    private let normalizer = TextNormalizer()

    // MARK: - Units

    func testOunceSpellingsNormalizeToOneString() {
        XCTAssertEqual(normalizer.normalize("12 OZ"), "12oz")
        XCTAssertEqual(normalizer.normalize("12OZ"), "12oz")
        XCTAssertEqual(normalizer.normalize("12-oz"), "12oz")
        XCTAssertEqual(normalizer.normalize("12 OZ"), normalizer.normalize("12OZ"))
    }

    func testCoveredUnitsJoinToTheNumber() {
        XCTAssertEqual(normalizer.normalize("500 ML"), "500ml")
        XCTAssertEqual(normalizer.normalize("250 g"), "250g")
        XCTAssertEqual(normalizer.normalize("2 LB"), "2lb")
        XCTAssertEqual(normalizer.normalize("24 ct"), "24ct")
        XCTAssertEqual(normalizer.normalize("1.5 L"), "1.5l")
    }

    func testUnitPrefixOfALongerWordIsNotJoined() {
        XCTAssertEqual(normalizer.normalize("5 grams"), "5 grams")
        XCTAssertEqual(normalizer.normalize("2 liters"), "2 liters")
    }

    // MARK: - Case, punctuation, whitespace

    func testCaseFoldsWithStableLocale() {
        XCTAssertEqual(normalizer.normalize("HONEY Nut CHEERIOS"), "honey nut cheerios")
    }

    func testPunctuationBecomesSeparatorExceptApostropheAndHyphen() {
        XCTAssertEqual(normalizer.normalize("Kellogg's® Raisin Bran!"), "kellogg's raisin bran")
        XCTAssertEqual(normalizer.normalize("Sugar-Free (Original)"), "sugar-free original")
        XCTAssertEqual(normalizer.normalize("NEW & IMPROVED"), "new improved")
    }

    func testDecimalPointInsideANumberIsPreserved() {
        XCTAssertEqual(normalizer.normalize("Family Size 18.8 OZ"), "family size 18.8oz")
        XCTAssertEqual(normalizer.normalize("Trailing period."), "trailing period")
    }

    func testRepeatedWhitespaceCollapses() {
        XCTAssertEqual(normalizer.normalize("  Honey   Nut\n\tCheerios  "), "honey nut cheerios")
    }

    func testUnicodeCanonicalFormIsApplied() {
        // e + combining acute vs precomposed é
        let decomposed = "Cafe\u{0301}"
        let precomposed = "Caf\u{00E9}"
        XCTAssertEqual(normalizer.normalize(decomposed), normalizer.normalize(precomposed))
    }

    func testDigitsAreKept() {
        XCTAssertEqual(normalizer.normalize("Pack of 6"), "pack of 6")
    }

    // MARK: - Tokens

    func testTokensContainWordsAndAdjacentBigrams() {
        let tokens = normalizer.tokens(from: "Honey Nut Cheerios 12 OZ")

        XCTAssertTrue(tokens.contains("honey"))
        XCTAssertTrue(tokens.contains("nut"))
        XCTAssertTrue(tokens.contains("cheerios"))
        XCTAssertTrue(tokens.contains("12oz"))
        XCTAssertTrue(tokens.contains("honey nut"))
        XCTAssertTrue(tokens.contains("nut cheerios"))
        XCTAssertTrue(tokens.contains("cheerios 12oz"))
        XCTAssertFalse(tokens.contains("honey cheerios"))
    }

    func testTokensOfSingleWordHaveNoBigram() {
        XCTAssertEqual(normalizer.tokens(from: "Cheerios"), ["cheerios"])
    }

    func testTokensOfEmptyStringAreEmpty() {
        XCTAssertEqual(normalizer.tokens(from: "   "), [])
    }

    func testNormalizationIsDeterministic() {
        let input = "Kellogg's® Frosted Flakes, 13.5 OZ"
        XCTAssertEqual(normalizer.normalize(input), normalizer.normalize(input))
    }
}
