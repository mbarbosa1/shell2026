import Foundation

/// Deterministic normalization shared by OCR output and, in a later slice,
/// catalog terms. Same input always produces the same output.
public protocol TextNormalizing: Sendable {
    func normalize(_ text: String) -> String
    func tokens(from text: String) -> Set<String>
}

/// The normalization pipeline from PROJECT_MEMORY.md, applied in this order:
///
/// 1. Unicode canonical normalization (NFC).
/// 2. Locale-stable case folding (`en_US_POSIX` lowercase).
/// 3. Drop punctuation that carries no product meaning. Apostrophe and hyphen
///    stay. A period or comma stays only when it sits between two digits.
/// 4. Collapse repeated whitespace.
/// 5. Join a number to a following unit so `12 OZ`, `12-oz`, and `12OZ` all
///    become `12oz`.
/// 6. Numbers are kept as tokens.
/// 7. Tokens are the words plus each adjacent word pair.

public struct TextNormalizer: TextNormalizing {
    public static let units: [String] = ["floz", "oz", "ml", "kg", "g", "lbs", "lb", "ct", "l", "pk"]

    private static let caseLocale = Locale(identifier: "en_US_POSIX")

    private static let unitJoin: NSRegularExpression = {
        let alternatives = units.joined(separator: "|")
        // number, optional whitespace/hyphen, unit, then a word boundary so
        // "5 grams" is not read as "5g rams".
        return try! NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)[\s-]*(\#(alternatives))\b"#
        )
    }()

    public init() {}

    public func normalize(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        let lowered = composed.lowercased(with: Self.caseLocale)
        let stripped = Self.stripPunctuation(lowered)
        let collapsed = Self.collapseWhitespace(stripped)
        return Self.joinUnits(collapsed)
    }

    public func tokens(from text: String) -> Set<String> {
        let words = normalize(text).split(separator: " ").map(String.init)
        var result = Set(words)
        if words.count >= 2 {
            for index in 0..<(words.count - 1) {
                result.insert("\(words[index]) \(words[index + 1])")
            }
        }
        return result
    }

    // MARK: - Steps

    private static func stripPunctuation(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)

        for index in scalars.indices {
            let scalar = scalars[index]
            if CharacterSet.alphanumerics.contains(scalar) {
                output.append(scalar)
            } else if scalar == "'" || scalar == "-" {
                output.append(scalar)
            } else if scalar == "." || scalar == "," {
                if isBetweenDigits(scalars, at: index) {
                    output.append(scalar)
                } else {
                    output.append(" ")
                }
            } else {
                // Whitespace and every other symbol become a separator.
                output.append(" ")
            }
        }
        return String(output)
    }

    private static func isBetweenDigits(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0, index < scalars.count - 1 else { return false }
        return CharacterSet.decimalDigits.contains(scalars[index - 1])
            && CharacterSet.decimalDigits.contains(scalars[index + 1])
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func joinUnits(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return unitJoin.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1$2"
        )
    }
}
