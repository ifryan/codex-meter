// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

private final class BoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        if data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
        lock.unlock()
    }

    func utf8String() -> String? {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexUsageClient: Sendable {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private let executableOverride: URL?
    private let parser = CodexUsageParser()

    init(executableOverride: URL? = nil) {
        self.executableOverride = executableOverride
    }

    func fetch() async throws -> UsageSnapshot {
        var lastError: Error = MeterError.noResponse(nil)
        for attempt in 0..<3 {
            do {
                return try await Task.detached(priority: .utility) {
                    try fetchOnce()
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 350_000_000)
                }
            }
        }
        throw lastError
    }

    private func fetchOnce() throws -> UsageSnapshot {
        let executable = try resolveCodexExecutable()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let stderrBuffer = BoundedDataBuffer(maximumBytes: 16 * 1_024)

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        errors.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw MeterError.launchFailed(error.localizedDescription)
        }

        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)

        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        var buffered = Data()

        func write(id: Int? = nil, method: String, params: Any? = nil) throws {
            var payload: [String: Any] = ["method": method]
            if let id { payload["id"] = id }
            if let params { payload["params"] = params }
            let data = try JSONSerialization.data(withJSONObject: payload)
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }

        func popResponse(id: Int) throws -> Data? {
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw MeterError.server(error["message"] as? String ?? "未知错误")
                }
                guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else {
                    throw MeterError.invalidResponse
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
            return nil
        }

        func readResponse(id: Int) throws -> Data {
            while true {
                if let response = try popResponse(id: id) { return response }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty {
                    if !buffered.isEmpty {
                        buffered.append(0x0A)
                        if let response = try popResponse(id: id) { return response }
                    }
                    throw MeterError.noResponse(stderrBuffer.utf8String())
                }
                buffered.append(chunk)
                if buffered.count > Self.maximumResponseBytes {
                    throw MeterError.responseTooLarge
                }
            }
        }

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        try write(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": ["name": "codex-meter", "version": appVersion],
                "capabilities": ["experimentalApi": true]
            ]
        )
        _ = try readResponse(id: 1)
        try write(method: "initialized")
        try write(id: 2, method: "account/rateLimits/read", params: NSNull())
        return try parser.parse(resultData: readResponse(id: 2))
    }

    private func resolveCodexExecutable() throws -> URL {
        if let executableOverride,
           FileManager.default.isExecutableFile(atPath: executableOverride.path) {
            return executableOverride.resolvingSymlinksInPath()
        }

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let configured = UserDefaults.standard.string(forKey: "codexExecutablePath"), !configured.isEmpty {
            candidates.append(configured)
        }
        if let configured = environment["CODEX_METER_CODEX_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        throw MeterError.codexNotFound
    }
}
