// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Looks up user-facing text. The key is the English string, so a missing translation shows English.
/// Translations live in `Resources/<language>.lproj/Localizable.strings`.
/// With arguments, the text is a format string: use `%@`, or `%1$@` and `%2$@` so a translation can
/// reorder them, and write a literal percent sign as `%%`.
func L(_ key: String, _ arguments: String...) -> String {
    let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

/// The language chosen in the app menu. `nil` follows macOS. Saved as this app's own `AppleLanguages`
/// value, which macOS reads at launch, so a change takes effect after a restart.
enum LanguagePreference {
    static let key = "AppleLanguages"
    /// Each language is listed under its own name, so it can be found from any interface language.
    static let options: [(code: String, name: String)] = [("en", "English"), ("zh-Hans", "简体中文")]

    /// Reads only this app's saved value. `UserDefaults.array(forKey:)` would also return the system list.
    static func current(in domain: [String: Any]?) -> String? {
        guard let code = (domain?[key] as? [String])?.first, options.contains(where: { $0.code == code }) else { return nil }
        return code
    }

    static var current: String? {
        current(in: Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) })
    }

    static func set(_ code: String?, defaults: UserDefaults = .standard) {
        if let code {
            defaults.set([code], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
