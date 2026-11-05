// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OSLog

enum AppEnvironment {
    /// Reads `METERLINE_<name>`, then the pre-rename `CODEX_METER_<name>`. Empty values count as unset.
    static func value(_ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for prefix in ["METERLINE_", "CODEX_METER_"] {
            if let value = environment[prefix + name], !value.isEmpty { return value }
        }
        return nil
    }

    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo") || value("DEMO") == "1"
    }
}

/// One-time move from the Codex Meter identity. The old directory and preferences are left in place,
/// so the old app still works if someone goes back to it.
enum LegacyMigration {
    static let directoryName = "Meterline"
    static let legacyDirectoryName = "CodexMeter"
    static let legacyBundleIdentifier = "io.github.ifryan.codexmeter"
    static let completedKey = "legacyMigrationCompleted"
    /// Install backups can hold whole app copies and aren't read by the app.
    static let excludedItems: Set<String> = ["backups"]

    /// Returns false when startup must stop, because continuing would create an empty configuration
    /// that hides the user's connections from every later migration attempt.
    @MainActor
    static func runAtLaunch() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return true }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        quitLegacyApp()
        do {
            try migrate(from: support.appendingPathComponent(legacyDirectoryName, isDirectory: true),
                        to: support.appendingPathComponent(directoryName, isDirectory: true),
                        legacyDefaults: defaults.persistentDomain(forName: legacyBundleIdentifier),
                        defaults: defaults)
            return true
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.meterline", category: "migration")
                .error("Migration failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = L("Couldn't migrate Codex Meter data")
            alert.informativeText = L("Your existing data wasn't changed. Check your disk space and the permissions of the Application Support folder, then reopen the app.\n\n%@", "\(error.localizedDescription)")
            alert.runModal()
            return false
        }
    }

    /// Copies through a temporary sibling, so an interrupted copy never looks like finished data.
    static func migrate(from legacy: URL, to destination: URL, legacyDefaults: [String: Any]?,
                        defaults: UserDefaults, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: destination.path) {
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent("\(directoryName).migrating-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                for item in try fileManager.contentsOfDirectory(atPath: legacy.path) where !excludedItems.contains(item) {
                    try fileManager.copyItem(at: legacy.appendingPathComponent(item), to: staging.appendingPathComponent(item))
                }
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: completedKey)
    }

    /// A running old copy could write to its database mid-copy, and would draw a second notch panel.
    @MainActor
    private static func quitLegacyApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleIdentifier)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
