import Foundation
import XCTest

/// The app's two catalogs (`AntresolTV/Resources/{en,ru}.lproj/Localizable.strings`: the key is the
/// English text) and the texts the views show: nothing reaches the screen as a raw key or a literal
/// without a Russian text, and the Russian text is Russian.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Texts that read the same in both languages (a brand, a name).
    private static let sameInBoth: Set<String> = ["Apple", "Antresol %@ · %@"]

    /// `<folder>/<language>.lproj/Localizable.strings` as key → text (keys and texts as written, escapes kept).
    private func catalog(_ folder: String, _ language: String) throws -> [String: String] {
        let file = Self.root.appendingPathComponent("\(folder)/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: file, encoding: .utf8)
        var out: [String: String] = [:]
        for match in text.matches(of: #/(?m)^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";/#) {
            let key = String(match.1)
            XCTAssertNil(out[key], "\(language): «\(key)» is in the catalog twice")
            out[key] = String(match.2)
        }
        return out
    }

    /// The keys of `<folder>/<language>.lproj/Localizable.stringsdict` (the plurals: «%lld songs»).
    private func pluralKeys(_ folder: String, _ language: String) throws -> Set<String> {
        let file = Self.root.appendingPathComponent("\(folder)/\(language).lproj/Localizable.stringsdict")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: file) as? [String: Any], "\(file.path) was not read")
        return Set(plist.keys)
    }

    private func placeholders(_ text: String) -> [String] {
        text.matches(of: #/%(?:\d+\$)?(?:l+d|d|@|f|\.\df)/#).map { String($0.0).replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        for folder in ["AntresolTV/Resources", "TopShelf"] {
            let en = try catalog(folder, "en"), ru = try catalog(folder, "ru")
            XCTAssertGreaterThan(en.count, folder == "TopShelf" ? 2 : 200, "\(folder): the English catalog was not read")
            XCTAssertEqual(Set(en.keys).subtracting(ru.keys).sorted(), [], "\(folder): no Russian text for")
            XCTAssertEqual(Set(ru.keys).subtracting(en.keys).sorted(), [], "\(folder): a Russian text no key asks for")
        }
    }

    func testBothLanguagesHaveTheSamePlurals() throws {
        let en = try pluralKeys("AntresolTV/Resources", "en"), ru = try pluralKeys("AntresolTV/Resources", "ru")
        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(en.subtracting(ru).sorted(), [], "no Russian plural for")
        XCTAssertEqual(ru.subtracting(en).sorted(), [], "a Russian plural no key asks for")
    }

    func testEveryTextIsTranslatedAndInItsLanguage() throws {
        let en = try catalog("AntresolTV/Resources", "en"), ru = try catalog("AntresolTV/Resources", "ru")
        for (key, english) in en {
            guard let russian = ru[key] else { continue }
            XCTAssertFalse(russian.isEmpty || english.isEmpty, "«\(key)» has an empty text")
            XCTAssertNil(english.firstMatch(of: #/[А-Яа-яЁё]/#), "en «\(key)» has Cyrillic")
            if !Self.sameInBoth.contains(key) {
                XCTAssertNotNil(russian.firstMatch(of: #/[А-Яа-яЁё]/#), "ru «\(key)» is not Russian: «\(russian)»")
            }
            XCTAssertEqual(placeholders(english).sorted(), placeholders(russian).sorted(), "«\(key)»: the placeholders differ")
        }
    }

    /// The texts a view hands to SwiftUI or `String(localized:)` as a literal are keys of the catalog:
    /// one that is not shows in English in the Russian interface.
    func testEveryLiteralTextOfTheViewsIsInTheCatalog() throws {
        let en = try catalog("AntresolTV/Resources", "en")
        // a plural reads `\(count) songs` in the code and `%lld songs` in the .stringsdict
        let known = Set(en.keys.map(Self.normalized)).union(try pluralKeys("AntresolTV/Resources", "en").map(Self.normalized))
        let sources = try XCTUnwrap(FileManager.default.enumerator(at: Self.root.appendingPathComponent("AntresolTV"), includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(sources.count, 50, "the sources were not found")
        // a call that takes user-visible text as its first literal, or a labelled argument of one
        let opening = #/\b(?:Text|Button|Label|Toggle|TextField|SecureField|Section|SettingsRowLabel|SettingsSection|SettingsInfoRow|navigationTitle|accessibilityLabel|accessibilityHint|confirmationDialog)\(\s*"|String\(localized:\s*"|\b(?:title|footnote|message|subtitle|placeholder|actionTitle|prompt):\s*"/#
        var missing: [String] = []
        for file in sources {
            for (number, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for match in line.matches(of: opening) {
                    guard let text = Self.literal(in: line, openingQuoteAt: line.index(before: match.range.upperBound)) else { continue }
                    // an identifier, a symbol name, a bare number is not for the catalog
                    guard text.contains(where: \.isLetter), text.contains(" ") || text.contains(where: \.isUppercase) || text.contains("%"),
                          text.contains(" ") || !text.contains(where: \.isNumber) else { continue }
                    if !known.contains(Self.normalized(text)) {
                        missing.append("\(file.lastPathComponent):\(number + 1) «\(text)»")
                    }
                }
            }
        }
        XCTAssertEqual(missing, [], "texts the catalog does not have")
    }

    /// The string literal whose opening quote is at `quote`, its interpolations (`\(…)`, nested quotes and
    /// parentheses included) as `%`. nil when the literal does not end on the line.
    private static func literal(in line: String, openingQuoteAt quote: String.Index) -> String? {
        var out = ""
        var i = line.index(after: quote)
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { return out }
            if c == "\\", line.index(after: i) < line.endIndex {
                let next = line[line.index(after: i)]
                if next == "(" {
                    var depth = 0, inner = false
                    var j = line.index(after: i)
                    while j < line.endIndex {
                        let d = line[j]
                        if d == "\"" { inner.toggle() }
                        if !inner, d == "(" { depth += 1 }
                        if !inner, d == ")" { depth -= 1; if depth == 0 { break } }
                        j = line.index(after: j)
                    }
                    guard j < line.endIndex else { return nil }
                    out += "%"
                    i = line.index(after: j)
                    continue
                }
                out.append(next)
                i = line.index(i, offsetBy: 2)
                continue
            }
            out.append(c)
            i = line.index(after: i)
        }
        return nil
    }

    /// `"Kid profile · up to \(rating)"` and `"Kid profile · up to %@"` are the same key.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"%(?:\d+\$)?(?:l+d|d|@)"#, with: "%", options: .regularExpression)
    }
}
