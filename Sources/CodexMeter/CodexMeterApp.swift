// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@main
struct CodexMeterApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
