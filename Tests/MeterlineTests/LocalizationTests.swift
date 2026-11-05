// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import Meterline

final class LocalizationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?@|%%")
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testEveryKeyHasChineseTranslationWithMatchingPlaceholders() throws {
        let stringsURL = root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let translations = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: stringsURL), format: nil) as? [String: String])
        let sources = root.appendingPathComponent("Sources/Meterline")
        let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let code = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in call.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                keys.insert(String(code[Range(match.range(at: 1), in: code)!])
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n"))
            }
        }
        XCTAssertGreaterThan(keys.count, 400)
        for key in keys {
            guard let translation = translations[key] else { XCTFail("Missing zh-Hans translation: \(key)"); continue }
            XCTAssertEqual(placeholders(key), placeholders(translation), key)
        }
        XCTAssertEqual(Set(translations.keys).subtracting(keys), [], "Translations no code uses")
    }

    func testLanguagePreferenceReadsOnlySupportedSavedChoice() {
        XCTAssertNil(LanguagePreference.current(in: nil))
        XCTAssertNil(LanguagePreference.current(in: ["AppleLanguages": ["fr"]]))
        XCTAssertEqual(LanguagePreference.current(in: ["AppleLanguages": ["zh-Hans"]]), "zh-Hans")
    }

    func testLanguagePreferenceSavesAndClearsChoice() throws {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LanguagePreference.set("en", defaults: defaults)
        XCTAssertEqual(LanguagePreference.current(in: defaults.persistentDomain(forName: suite)), "en")
        LanguagePreference.set(nil, defaults: defaults)
        XCTAssertNil(LanguagePreference.current(in: defaults.persistentDomain(forName: suite)))
    }

    func testFormattingSubstitutesAndKeepsPercentSigns() {
        XCTAssertEqual(L("%@%% left", "52"), "52% left")
        XCTAssertEqual(L("%1$@ (%2$@)", "a", "b"), "a (b)")
    }

    /// Billing event IDs contain these values, so they must not depend on the language.
    func testStoredLabelsAreEnglishAndTranslateOnlyForDisplay() {
        XCTAssertEqual(StoredLabel.organizationBill, "Organization bill (not split by model)")
        XCTAssertEqual(StoredLabel.display(StoredLabel.organizationBill), "Organization bill (not split by model)")
        XCTAssertEqual(StoredLabel.display("gpt-5"), "gpt-5")
        XCTAssertEqual(MonitorFormat.amount(3, unit: MonitorFormat.countUnit), "3 uses")
    }
}
