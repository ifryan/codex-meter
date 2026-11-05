// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct LogCursor: Codable, Sendable {
    var offset: UInt64 = 0
    var inode: UInt64 = 0
    var size: UInt64 = 0
    var modified: Date? = nil
    var session: String = ""
    var model: String = "unknown"
    var input: Int64 = 0
    var output: Int64 = 0
    var cached: Int64 = 0
}

actor UsageLogScanner {
    static let defaults: [String: String] = [
        "codex": "~/.codex/sessions", "claude": "~/.claude/projects", "gemini": "~/.gemini/tmp",
        "opencode": "~/.local/share/opencode", "pi": "~/.pi/agent/sessions",
        "kimi": "~/.kimi/sessions", "minimax": "~/.minimax/sessions"
    ]
    private var scanning = false

    func scan(configuration: MonitorConfiguration, history: UsageHistory) async throws -> String {
        guard configuration.logsEnabled, !scanning else { return "本地日志采集未启用或正在进行" }
        scanning = true
        defer { scanning = false }
        var imported = 0
        var errors = 0
        for tool in Self.defaults.keys.sorted() {
            let path = configuration.logRoots[tool] ?? Self.defaults[tool]!
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            if tool == "opencode" {
                let database = root.pathExtension == "db" ? root : root.appendingPathComponent("opencode.db")
                if FileManager.default.fileExists(atPath: database.path) {
                    do { imported += try await scanOpenCodeDatabase(database, account: configuration.logAccountIDs[tool], prices: configuration.prices, history: history) }
                    catch is CancellationError { throw CancellationError() }
                    catch { errors += 1 }
                    // A migrated installation may retain JSON copies of the same records.
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                guard ["jsonl", "json"].contains(file.pathExtension.lowercased()),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                // Gemini stores credentials and other JSON beside chats; only its session files are usage inputs.
                if tool == "gemini" && (!file.path.contains("/chats/") || !file.lastPathComponent.hasPrefix("session-")) { continue }
                do {
                    let data = try await history.readCursor(file.path)
                    var cursor = data.flatMap { try? JSONDecoder().decode(LogCursor.self, from: $0) } ?? LogCursor()
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    if cursor.inode != inode || size < cursor.offset { cursor = LogCursor(session: file.deletingPathExtension().lastPathComponent) }
                    if cursor.session.isEmpty { cursor.session = file.deletingPathExtension().lastPathComponent }
                    if cursor.size == size && cursor.modified == values.contentModificationDate { continue }
                    cursor.inode = inode
                    let events: [UsageEvent]
                    if file.pathExtension == "jsonl" {
                        events = try Self.readLines(file, tool: tool, cursor: &cursor, account: configuration.logAccountIDs[tool])
                    } else {
                        guard size <= 16_777_216 else { errors += 1; continue }
                        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                        events = Self.readDocument(root, tool: tool, cursor: &cursor, account: configuration.logAccountIDs[tool])
                    }
                    let priced = events.map { event -> UsageEvent in var event = event; event.price(using: configuration.prices); return event }
                    try await history.insert(priced)
                    cursor.size = size; cursor.modified = values.contentModificationDate
                    try await history.saveCursor(file.path, data: JSONEncoder().encode(cursor))
                    imported += events.count
                } catch is CancellationError { throw CancellationError() }
                catch { errors += 1 }
            }
        }
        try await history.prune(days: configuration.historyDays)
        return "本次处理 \(imported) 条用量记录（按稳定 ID 去重）" + (errors > 0 ? "；\(errors) 个文件暂不可读" : "")
    }

    private func scanOpenCodeDatabase(_ url: URL, account: UUID?, prices: [ModelPrice], history: UsageHistory) async throws -> Int {
        let saved = try await history.readCursor(url.path)
        var cursor = saved.flatMap { try? JSONDecoder().decode(LogCursor.self, from: $0) } ?? LogCursor()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if cursor.inode != inode { cursor = LogCursor() }
        cursor.inode = inode
        var events: [UsageEvent] = []
        try ReadOnlySQLite.visit(path: url.path, query: "SELECT id, session_id, time_created, time_updated, data FROM message WHERE time_updated>=? ORDER BY time_updated,id", after: Int64(min(cursor.offset, UInt64(Int64.max)))) { row in
            guard let text = row["data"], let data = text.data(using: .utf8), var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            root["id"] = row["id"]
            root["timestamp"] = row["time_created"]
            cursor.session = row["session_id"] ?? "unknown"
            if let updated = row["time_updated"].flatMap(UInt64.init) { cursor.offset = max(cursor.offset, updated) }
            if var event = Self.parse(root, tool: "opencode", cursor: &cursor, account: account) {
                event.price(using: prices); events.append(event)
            }
        }
        try await history.insert(events)
        try await history.saveCursor(url.path, data: JSONEncoder().encode(cursor))
        return events.count
    }

    private static func readLines(_ file: URL, tool: String, cursor: inout LogCursor, account: UUID?) throws -> [UsageEvent] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        var pending = Data()
        var result: [UsageEvent] = []
        var dropping = false
        while let block = try handle.read(upToCount: 131_072), !block.isEmpty {
            try Task.checkCancellation()
            pending.append(block)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                pending.removeFirst(consumed); cursor.offset += UInt64(consumed)
                if !dropping, line.count <= 1_048_576, let root = try? JSONSerialization.jsonObject(with: line),
                   let event = parse(root, tool: tool, cursor: &cursor, account: account) { result.append(event) }
                dropping = false
            }
            if pending.count > 1_048_576 { cursor.offset += UInt64(pending.count); pending.removeAll(keepingCapacity: true); dropping = true }
        }
        // A writer may still be appending its last line. Leave incomplete bytes for the next scan.
        return result
    }

    static func readDocument(_ root: Any, tool: String, cursor: inout LogCursor, account: UUID?) -> [UsageEvent] {
        if let id = JSONField.text(root, "sessionId") ?? JSONField.text(root, "sessionID") { cursor.session = id }
        if tool == "gemini" {
            return (JSONField.value(root, at: "messages") as? [[String: Any]] ?? []).compactMap { parse($0, tool: tool, cursor: &cursor, account: account) }
        }
        return parse(root, tool: tool, cursor: &cursor, account: account).map { [$0] } ?? []
    }

    static func parse(_ root: Any, tool: String, cursor: inout LogCursor, account: UUID?) -> UsageEvent? {
        guard let object = root as? [String: Any] else { return nil }
        if let session = JSONField.text(root, "sessionId") ?? JSONField.text(root, "session_id") { cursor.session = session }
        let type = JSONField.text(root, "type") ?? ""
        if tool == "codex" {
            if type == "session_meta", let id = JSONField.text(root, "payload.id") { cursor.session = id; return nil }
            if type == "turn_context", let model = JSONField.text(root, "payload.model") { cursor.model = model; return nil }
            guard type == "event_msg", JSONField.text(root, "payload.type") == "token_count",
                  let usage = JSONField.value(root, at: "payload.info.total_token_usage"),
                  let date = JSONField.date(object["timestamp"]), let input = count(usage, "input_tokens"),
                  let output = count(usage, "output_tokens") else { return nil }
            let cached = count(usage, "cached_input_tokens") ?? 0
            let deltaInput = input >= cursor.input ? input - cursor.input : input
            let deltaOutput = output >= cursor.output ? output - cursor.output : output
            let deltaCached = cached >= cursor.cached ? cached - cursor.cached : cached
            cursor.input = input; cursor.output = output; cursor.cached = cached
            guard deltaInput + deltaOutput > 0 else { return nil }
            return UsageEvent(id: UsageImport.eventID(tool: tool, session: cursor.session, request: "\(input)|\(output)|\(cached)|\(date.timeIntervalSince1970)"),
                timestamp: date, tool: tool, accountID: account, model: cursor.model,
                inputTokens: max(0, deltaInput - deltaCached), outputTokens: deltaOutput, cacheReadTokens: deltaCached)
        }
        let message = object["message"] as? [String: Any] ?? object
        let role = JSONField.text(message, "role") ?? type
        guard ["assistant", "gemini", "message"].contains(role) || type == "assistant" else { return nil }
        let usage = JSONField.value(message, at: "usage") ?? JSONField.value(message, at: "tokens")
        guard let usage, let date = JSONField.date(object["timestamp"] ?? JSONField.value(message, at: "timestamp") ?? JSONField.value(message, at: "time.created")) else { return nil }
        let model = JSONField.text(message, "model") ?? JSONField.text(message, "modelID") ?? JSONField.text(root, "model") ?? "unknown"
        let rawInput = count(usage, "input_tokens") ?? count(usage, "input") ?? 0
        let rawOutput = count(usage, "output_tokens") ?? count(usage, "output") ?? 0
        let cached = count(usage, "cache_read_input_tokens") ?? count(usage, "cacheRead") ?? count(usage, "cache.read") ?? count(usage, "cached") ?? 0
        let written = count(usage, "cache_creation_input_tokens") ?? count(usage, "cacheWrite") ?? count(usage, "cache.write") ?? 0
        guard rawInput + rawOutput + cached + written > 0 else { return nil }
        let request = JSONField.text(message, "id") ?? JSONField.text(root, "uuid") ?? "\(date.timeIntervalSince1970)|\(model)"
        let rawCost = JSONField.number(usage, "cost.total") ?? (tool == "opencode" ? JSONField.number(message, "cost") : nil)
        let knownCost = rawCost.flatMap { $0 > 0 ? $0 : nil }
        return UsageEvent(id: UsageImport.eventID(tool: tool, session: cursor.session, request: request), timestamp: date, tool: tool,
            accountID: account, model: model, inputTokens: tool == "gemini" ? max(0, rawInput - cached) : rawInput,
            outputTokens: rawOutput + (tool == "gemini" ? count(usage, "thoughts") ?? 0 : 0),
            cacheReadTokens: cached, cacheWriteTokens: written,
            cost: knownCost, origin: knownCost == nil ? .localLog : .estimate,
            priceVersion: knownCost == nil ? nil : "日志中的价格估算")
    }

    private static func count(_ object: Any, _ path: String) -> Int64? {
        guard let value = JSONField.number(object, path), value >= 0, value <= Decimal(Int64.max / 8) else { return nil }
        return NSDecimalNumber(decimal: value).int64Value
    }
}
