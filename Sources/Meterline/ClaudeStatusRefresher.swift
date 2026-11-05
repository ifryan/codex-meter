// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Asks the `claude` CLI to refresh its own OAuth session, by running it on a pseudo-terminal and
/// sending `/status`.
///
/// Claude Code's Keychain token expires roughly every 8 hours and is renewed only while the CLI is
/// running. Refreshing it ourselves would mean writing that Keychain item, racing Claude Code's own
/// refresh-token rotation, so we let the CLI do the write and just watch for the item to change.
/// The CLI has no non-interactive command that touches the auth path — `claude auth status` does
/// not refresh — hence the terminal automation.
///
/// This is only the *second* fallback: it spawns a process, so it runs behind a cooldown and only
/// after the header channel has already failed.
enum ClaudeStatusRefresher {
    /// Never spawn the CLI more often than this, however often refresh() is called.
    static let cooldown: TimeInterval = 10 * 60

    private static let lock = NSLock()
    private static var lastAttemptAt: Date?

    /// `claude` shows a "do you trust this folder" prompt in an unfamiliar directory, which would
    /// swallow the `/status` we send. Running inside a directory the user already trusted avoids
    /// the prompt entirely rather than trying to answer it blind.
    static func trustedWorkingDirectory(
        configPath: String = NSHomeDirectory() + "/.claude.json"
    ) -> URL? {
        guard
            let data = FileManager.default.contents(atPath: configPath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = json["projects"] as? [String: Any]
        else {
            return nil
        }
        let trusted = projects.compactMap { path, value -> String? in
            guard
                let settings = value as? [String: Any],
                settings["hasTrustDialogAccepted"] as? Bool == true,
                FileManager.default.fileExists(atPath: path)
            else {
                return nil
            }
            return path
        }
        // Sorted so the choice is stable across runs rather than dictionary-order roulette.
        return trusted.sorted().first.map { URL(fileURLWithPath: $0) }
    }

    static func claudeBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = AppEnvironment.value("CLAUDE_PATH", in: environment) {
            return URL(fileURLWithPath: override)
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Returns true if the Claude Code Keychain item changed, i.e. the CLI really did refresh.
    /// A `false` return is not an error: if the stored token is still valid the CLI has no reason
    /// to rewrite it.
    @discardableResult
    static func refresh(timeout: TimeInterval = 20, now: Date = Date()) -> Bool {
        // Starting Claude while the keychain is locked can also request a password.
        guard ClaudeKeychainReader.isDefaultKeychainUnlocked else { return false }
        lock.lock()
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldown {
            lock.unlock()
            return false
        }
        lastAttemptAt = now
        lock.unlock()

        guard
            let binary = claudeBinaryURL(),
            let workingDirectory = trustedWorkingDirectory()
        else {
            return false
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            return false
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return false
        }
        defer {
            close(master)
            close(slave)
        }

        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = workingDirectory
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // Without a plausible viewport the CLI's TUI can refuse to lay out at all.
        environment["COLUMNS"] = "100"
        environment["LINES"] = "40"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return false
        }
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let baseline = ClaudeCodeSessionStore.tokenFingerprint()
        let deadline = now.addingTimeInterval(timeout)
        var sentStatus = false
        while Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.4)
            // Give the TUI a moment to come up before typing into it.
            if !sentStatus, Date() >= now.addingTimeInterval(4) {
                _ = "/status\r".withCString { write(master, $0, strlen($0)) }
                sentStatus = true
                continue
            }
            if sentStatus, ClaudeCodeSessionStore.tokenFingerprint() != baseline {
                return true
            }
        }
        return false
    }
}
