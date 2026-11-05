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
