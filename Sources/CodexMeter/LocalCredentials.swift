// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import Darwin

enum ReadOnlySQLite {
    static func text(path: String, key: String) throws -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        if FileManager.default.fileExists(atPath: expanded + "-wal") && !FileManager.default.fileExists(atPath: expanded + "-shm") {
            throw MonitorError.message("应用数据库正在切换状态，请稍后再试")
        }
        var database: OpaquePointer?
        var components = URLComponents(url: URL(fileURLWithPath: expanded), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "mode", value: "ro")]
        if !FileManager.default.fileExists(atPath: expanded + "-wal") { components.queryItems?.append(.init(name: "immutable", value: "1")) }
        guard sqlite3_open_v2(components.string!, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw MonitorError.message("无法读取应用数据库，请使用网页登录或手动凭据")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= 1_048_576 else { return nil }
        let data = Data(bytes: bytes, count: count)
        if data.contains(0), let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        return String(data: data, encoding: .utf8)
    }

    static func visit(path: String, query: String, after: Int64, row: ([String: String]) -> Void) throws {
        let file = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: file) else { return }
        let hasWAL = FileManager.default.fileExists(atPath: file + "-wal")
        if hasWAL && !FileManager.default.fileExists(atPath: file + "-shm") { throw MonitorError.message("数据库正在切换状态，请稍后再试") }
        var url = URLComponents(url: URL(fileURLWithPath: file), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "mode", value: "ro")]
        if !hasWAL { url.queryItems?.append(.init(name: "immutable", value: "1")) }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.string!, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let pointer { sqlite3_close(pointer) }; throw MonitorError.message("应用数据库暂不可读")
        }
        defer { sqlite3_close(pointer) }
        sqlite3_busy_timeout(pointer, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, query, -1, &statement, nil) == SQLITE_OK else { throw MonitorError.message("应用数据库格式不受支持") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, after)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            var object: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_bytes(statement, column) <= 1_048_576,
                      let name = sqlite3_column_name(statement, column), let value = sqlite3_column_text(statement, column) else { continue }
                object[String(cString: name)] = String(cString: value)
            }
            row(object)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw MonitorError.message("应用数据库读取未完成") }
    }
}

enum LocalCredentials {
    static func jsonFile(_ path: String) throws -> Any {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4_194_304 else { throw MonitorError.invalidResponse }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    static func jwt(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func read(_ account: SourceAccount) async throws -> [String: String] {
        try await Task.detached(priority: .utility) {
            if account.sourceID == "claude", account.authentication == .local {
                guard let session = ClaudeCodeSessionStore.read(), !session.isExpired else { throw MonitorError.notConfigured }
                return ["token": session.accessToken]
            }
            if account.sourceID == "cursor", account.authentication == .local {
                let path = account.credentialPath.isEmpty ? "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb" : account.credentialPath
                var token = try ReadOnlySQLite.text(path: path, key: "cursorAuth/accessToken")
                if token == nil {
                    for file in ["~/.config/cursor/auth.json", "~/Library/Application Support/cursor/auth.json"] {
                        if let root = try? jsonFile(file), let found = JSONField.text(root, "accessToken") { token = found; break }
                    }
                }
                guard let token, !token.hasPrefix("cursor-safe-storage:"), let claims = jwt(token),
                      let user = claims["sub"] as? String,
                      let expires = JSONField.date(claims["exp"]), expires.timeIntervalSinceNow > 60 else {
                    throw MonitorError.message("Cursor 本机登录态不可读或已过期，请连接网页账户 / Cookie")
                }
                return ["cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)"]
            }
            if account.sourceID == "copilot", account.authentication == .local {
                for path in ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"] {
                    if let root = try? jsonFile(path) as? [String: Any] {
                        for key in root.keys.sorted() where key.hasPrefix("github.com") {
                            if let item = root[key], let token = JSONField.text(item, "oauth_token") { return ["token": token] }
                        }
                    }
                }
                throw MonitorError.message("未发现 Copilot 登录态，请使用 GitHub 登录按钮")
            }
            let fallback: String
            switch account.sourceID {
            case "codex": fallback = "~/.codex/auth.json"
            case "claude": fallback = "~/.claude/.credentials.json"
            case "gemini": fallback = "~/.gemini/oauth_creds.json"
            default: fallback = ""
            }
            let path = account.credentialPath.isEmpty ? fallback : account.credentialPath
            guard !path.isEmpty else { throw MonitorError.message("请选择此账户自己的 OAuth JSON 文件") }
            let root = try jsonFile(path)
            let token = JSONField.text(root, "tokens.access_token") ?? JSONField.text(root, "claudeAiOauth.accessToken")
                ?? JSONField.text(root, "access_token") ?? JSONField.text(root, "accessToken")
            guard let token, !token.isEmpty else { throw MonitorError.notConfigured }
            if let expires = JSONField.date(JSONField.value(root, at: "expiry_date") ?? JSONField.value(root, at: "claudeAiOauth.expiresAt")), expires <= Date() {
                throw MonitorError.message("本机 OAuth 已过期，请通过原工具登录续期，或重新连接账户")
            }
            var output = ["token": token]
            output["accountID"] = JSONField.text(root, "tokens.account_id")
            output["projectID"] = JSONField.text(root, "project_id")
            return output
        }.value
    }
}

final class CommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data); if bytes.count > 1_048_576 { bytes.removeFirst(bytes.count - 1_048_576) } }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(data: bytes, encoding: .utf8) ?? "" }
}

enum MonitorCommand {
    static func output(executable: String, arguments: [String]) async throws -> String {
        let task = Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            let buffer = CommandBuffer()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw MonitorError.message("无法创建 CLI 读取通道")
            }
            try process.run()
            try? pipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(22)
            func drain() {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                for _ in 0..<32 {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    guard count > 0 else { break }
                    buffer.append(Data(bytes.prefix(count)))
                }
            }
            while process.isRunning && Date() < deadline && !Task.isCancelled {
                var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&ready, 1, 50)
                drain()
            }
            let timedOut = process.isRunning && !Task.isCancelled
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.15)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            drain()
            try Task.checkCancellation()
            guard !timedOut else { throw MonitorError.message("CLI 读取超时，请检查登录状态") }
            guard process.terminationStatus == 0 else { throw MonitorError.message("CLI 读取未完成，请检查是否已登录或在设置中指定路径") }
            return buffer.text()
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
