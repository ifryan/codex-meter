// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@main
struct MeterlineApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        if !AppEnvironment.isDemo, !LegacyMigration.runAtLaunch() { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
