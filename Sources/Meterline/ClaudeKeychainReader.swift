// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security

/// Uses the system tool already trusted by credentials created with `security`.
/// Unlike this app's ad-hoc signature, its identity survives Meter rebuilds.
/// Secrets travel only through a pipe; never through arguments, files, or logs.
enum ClaudeKeychainReader {
    static var isDefaultKeychainUnlocked: Bool {
        var status: SecKeychainStatus = 0
        return SecKeychainGetStatus(nil, &status) == errSecSuccess
            && status & UInt32(kSecUnlockStateStatus) != 0
    }

    static func read(service: String, account: String? = nil) -> Data? {
        // Do not ask the system tool to unlock the user's login keychain.
        guard isDefaultKeychainUnlocked else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments.append(contentsOf: ["-a", account]) }
        arguments.append("-w")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        try? output.fileHandleForWriting.close()

        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= 64 * 1_024 else { return nil }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }

        // `security -w` appends a newline to the stored value.
        if data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}
