// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import CryptoKit

struct UsageEvent: Codable, Equatable, Sendable {
    var id: String
    var timestamp: Date
    var tool: String
    var accountID: UUID? = nil
    var model: String
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var cost: Decimal? = nil
    var currency: String = "USD"
    var origin: MeasurementOrigin = .localLog
    var priceVersion: String? = nil
    var dataset: UsageDataset = .local
    var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    mutating func price(using prices: [ModelPrice]) {
        guard cost == nil, let price = prices.first(where: { $0.model == model }),
              cacheReadTokens == 0 || price.cacheReadPerMillion != nil,
              cacheWriteTokens == 0 || price.cacheWritePerMillion != nil else { return }
        cost = (Decimal(inputTokens) * price.inputPerMillion + Decimal(outputTokens) * price.outputPerMillion
                + Decimal(cacheReadTokens) * (price.cacheReadPerMillion ?? 0)
                + Decimal(cacheWriteTokens) * (price.cacheWritePerMillion ?? 0)) / 1_000_000
        currency = price.currency
        origin = .estimate
        priceVersion = price.version
    }
}

struct UsageAggregate: Identifiable, Sendable {
    var id: String
    var label: String
    var currency: String
    var origin: MeasurementOrigin
    var tokens: Int64 = 0
    var requests: Int = 0
    var cost: Decimal = 0
    var unpriced: Int = 0
}

struct UsageDay: Identifiable, Sendable {
    var date: Date
    var tokens: Int64 = 0
    var costs: [String: Decimal] = [:]
    var id: Date { date }
}

struct UsageReport: Sendable {
    var groups: [UsageAggregate] = []
    var days: [UsageDay] = []
    var since: Date
    var until: Date
}

enum UsageGrouping: String, CaseIterable, Identifiable {
    case tool, account, model
    var id: String { rawValue }
    var title: String { switch self { case .tool: return "工具"; case .account: return "账户"; case .model: return "模型" } }
}

enum UsageDataset: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, imported, provider
    var id: String { rawValue }
    var title: String { switch self { case .local: return "本地日志"; case .imported: return "已有工具导出"; case .provider: return "服务商账单" } }
}

final class HistoryConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var database: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw MonitorError.message("无法打开本地用量数据库")
        }
        pointer = database
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(pointer, 3_000)
    }
    deinit { sqlite3_close(pointer) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw MonitorError.message("本地历史存储失败，原始数据已保留") }
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &value, nil) == SQLITE_OK, let value else { throw MonitorError.message("无法读取本地历史数据") }
        return value
    }
    static func bind(_ text: String?, _ index: Int32, to statement: OpaquePointer) {
        if let text { sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        else { sqlite3_bind_null(statement, index) }
    }
    static func string(_ index: Int32, from statement: OpaquePointer) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

actor UsageHistory {
    private let db: HistoryConnection
    init(url: URL = MonitorFiles.directory.appendingPathComponent("usage.sqlite")) throws {
        db = try HistoryConnection(url: url)
        try db.execute("PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON;")
        let version = try db.statement("PRAGMA user_version")
        let versionStatus = sqlite3_step(version)
        let schemaVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard versionStatus == SQLITE_ROW, schemaVersion <= 2 else {
            throw MonitorError.message("历史数据库版本比当前应用更新，请升级应用")
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY, time REAL NOT NULL, tool TEXT NOT NULL, account TEXT, model TEXT NOT NULL,
          input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
          cost TEXT, currency TEXT NOT NULL, origin TEXT NOT NULL, price_version TEXT);
        CREATE INDEX IF NOT EXISTS event_time ON events(time);
        CREATE TABLE IF NOT EXISTS snapshots (account TEXT NOT NULL, slot INTEGER NOT NULL, time REAL NOT NULL, data BLOB NOT NULL, PRIMARY KEY(account,slot));
        CREATE TABLE IF NOT EXISTS cursors (path TEXT PRIMARY KEY, data BLOB NOT NULL);
        """)
        if schemaVersion < 2 {
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("ALTER TABLE events ADD COLUMN dataset TEXT NOT NULL DEFAULT 'local'; UPDATE events SET dataset='imported' WHERE tool='cc-switch'; PRAGMA user_version=2; COMMIT;")
            } catch { try? db.execute("ROLLBACK"); throw error }
        }
    }

    func insert(_ events: [UsageEvent]) throws {
        guard !events.isEmpty else { return }
        try db.execute("BEGIN IMMEDIATE")
        do {
            let statement = try db.statement("""
            INSERT INTO events (id,time,tool,account,model,input,output,cache_read,cache_write,cost,currency,origin,price_version,dataset) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              input=CASE WHEN excluded.dataset='provider' THEN excluded.input ELSE MAX(events.input,excluded.input) END,
              output=CASE WHEN excluded.dataset='provider' THEN excluded.output ELSE MAX(events.output,excluded.output) END,
              account=COALESCE(events.account,excluded.account),
              cache_read=CASE WHEN excluded.dataset='provider' THEN excluded.cache_read ELSE MAX(events.cache_read,excluded.cache_read) END,
              cache_write=CASE WHEN excluded.dataset='provider' THEN excluded.cache_write ELSE MAX(events.cache_write,excluded.cache_write) END,
              cost=CASE WHEN excluded.dataset='provider' THEN excluded.cost WHEN events.cost IS NULL THEN excluded.cost
                WHEN excluded.cost IS NOT NULL AND events.price_version IS excluded.price_version
                  AND (excluded.input>events.input OR excluded.output>events.output OR excluded.cache_read>events.cache_read OR excluded.cache_write>events.cache_write)
                THEN excluded.cost ELSE events.cost END,
              currency=CASE WHEN events.cost IS NULL THEN excluded.currency ELSE events.currency END,
              origin=CASE WHEN events.cost IS NULL THEN excluded.origin ELSE events.origin END,
              price_version=CASE WHEN events.cost IS NULL THEN excluded.price_version ELSE events.price_version END
            """)
            defer { sqlite3_finalize(statement) }
            for event in events {
                guard [event.inputTokens, event.outputTokens, event.cacheReadTokens, event.cacheWriteTokens].allSatisfy({ $0 >= 0 && $0 <= Int64.max / 8 }),
                      event.cost?.isNaN != true else { continue }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                HistoryConnection.bind(event.id, 1, to: statement)
                sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
                HistoryConnection.bind(event.tool, 3, to: statement)
                HistoryConnection.bind(event.accountID?.uuidString, 4, to: statement)
                HistoryConnection.bind(event.model, 5, to: statement)
                for (index, value) in [event.inputTokens, event.outputTokens, event.cacheReadTokens, event.cacheWriteTokens].enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 6), value)
                }
                HistoryConnection.bind(event.cost.map { NSDecimalNumber(decimal: $0).stringValue }, 10, to: statement)
                HistoryConnection.bind(event.currency, 11, to: statement)
                HistoryConnection.bind(event.origin.rawValue, 12, to: statement)
                HistoryConnection.bind(event.priceVersion, 13, to: statement)
                HistoryConnection.bind(event.dataset.rawValue, 14, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitorError.message("用量记录写入失败") }
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }

    func record(_ snapshot: MonitorSnapshot) throws {
        let statement = try db.statement("INSERT OR REPLACE INTO snapshots VALUES (?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        var cached = snapshot
        cached.usageEvents = []
        let data = try JSONEncoder().encode(cached)
        HistoryConnection.bind(snapshot.accountID.uuidString, 1, to: statement)
        sqlite3_bind_int64(statement, 2, Int64(snapshot.fetchedAt.timeIntervalSince1970 / 900))
        sqlite3_bind_double(statement, 3, snapshot.fetchedAt.timeIntervalSince1970)
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitorError.message("无法保存额度历史") }
    }

    func latest(_ id: UUID) throws -> MonitorSnapshot? {
        let statement = try db.statement("SELECT data FROM snapshots WHERE account=? ORDER BY time DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        HistoryConnection.bind(id.uuidString, 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(MonitorSnapshot.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    func forgetSnapshots(_ id: UUID) throws {
        let statement = try db.statement("DELETE FROM snapshots WHERE account=?")
        defer { sqlite3_finalize(statement) }
        HistoryConnection.bind(id.uuidString, 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitorError.message("无法清理旧账户快照") }
    }

    func report(days: Int, grouping: UsageGrouping, dataset: UsageDataset = .local, activeProviderScopes: [UUID: UUID]? = nil, now: Date = Date()) throws -> UsageReport {
        var calendar = Calendar.current
        if dataset == .provider { calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)! }
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now))!
        let condition = "dataset = '\(dataset.rawValue)'"
        let statement = try db.statement("SELECT time,tool,account,model,input,output,cache_read,cache_write,cost,currency,origin,id FROM events WHERE time>=? AND time<=? AND \(condition) ORDER BY time")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        var groups: [String: UsageAggregate] = [:]
        var daily: [Date: UsageDay] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if dataset == .provider, let activeProviderScopes {
                let account = HistoryConnection.string(2, from: statement).flatMap(UUID.init(uuidString:))
                let id = HistoryConnection.string(11, from: statement) ?? ""
                guard let account, let scope = activeProviderScopes[account], id.hasPrefix("provider:\(account.uuidString):\(scope.uuidString):") else {
                    step = sqlite3_step(statement); continue
                }
            }
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let label = HistoryConnection.string(grouping == .tool ? 1 : grouping == .account ? 2 : 3, from: statement) ?? "未归属"
            let tokens = (4...7).reduce(Int64(0)) { $0 + sqlite3_column_int64(statement, Int32($1)) }
            let cost = HistoryConnection.string(8, from: statement).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            let currency = HistoryConnection.string(9, from: statement) ?? "USD"
            let origin = MeasurementOrigin(rawValue: HistoryConnection.string(10, from: statement) ?? "localLog") ?? .localLog
            let key = label + "|" + currency + "|" + origin.rawValue
            var group = groups[key] ?? UsageAggregate(id: key, label: label, currency: currency, origin: origin)
            group.tokens += tokens; group.requests += 1
            if let cost { group.cost += cost } else { group.unpriced += 1 }
            groups[key] = group
            let day = calendar.startOfDay(for: date)
            var bucket = daily[day] ?? UsageDay(date: day)
            bucket.tokens += tokens
            if let cost { bucket.costs[currency + "|" + origin.rawValue, default: 0] += cost }
            daily[day] = bucket
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw MonitorError.message("历史查询未完成，请重试") }
        return UsageReport(groups: groups.values.sorted { $0.tokens > $1.tokens }, days: daily.values.sorted { $0.date < $1.date }, since: start, until: now)
    }

    func readCursor(_ path: String) throws -> Data? {
        let statement = try db.statement("SELECT data FROM cursors WHERE path=?")
        defer { sqlite3_finalize(statement) }
        HistoryConnection.bind(path, 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func saveCursor(_ path: String, data: Data) throws {
        let statement = try db.statement("INSERT OR REPLACE INTO cursors VALUES (?,?)")
        defer { sqlite3_finalize(statement) }
        HistoryConnection.bind(path, 1, to: statement)
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitorError.message("无法保存日志导入进度") }
    }

    func prune(days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(max(30, days)) * 86_400).timeIntervalSince1970
        for table in ["events", "snapshots"] {
            let statement = try db.statement("DELETE FROM \(table) WHERE time < ?")
            sqlite3_bind_double(statement, 1, cutoff)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitorError.message("历史清理失败") }
        }
    }

    func clear() throws {
        try db.execute("BEGIN IMMEDIATE; DELETE FROM events; DELETE FROM snapshots; COMMIT; VACUUM;")
    }

    func resetImportPositions() throws { try db.execute("DELETE FROM cursors") }
}

enum UsageImport {
    static func eventID(tool: String, session: String, request: String) -> String {
        SHA256.hash(data: Data((tool + "|" + session + "|" + request).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ path: String, accountID: UUID) async throws -> [UsageEvent] {
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1_024 * 1_024 else { throw MonitorError.message("导出文件超过 64 MB，请按月份拆分") }
            let data = try Data(contentsOf: url)
            let objects: [[String: Any]]
            if url.pathExtension.lowercased() == "csv" {
                let rows = csv(String(decoding: data, as: UTF8.self))
                guard let headers = rows.first else { return [] }
                guard Set(headers).count == headers.count else { throw MonitorError.message("CSV 列名重复") }
                objects = rows.dropFirst().filter { $0.count == headers.count }.map { Dictionary(uniqueKeysWithValues: zip(headers, $0)) }
            } else {
                let root = try JSONSerialization.jsonObject(with: data)
                guard let records = root as? [[String: Any]] ?? JSONField.value(root, at: "records") as? [[String: Any]] ?? JSONField.value(root, at: "requests") as? [[String: Any]] else {
                    throw MonitorError.message("导出 JSON 需为记录数组，或包含 records / requests 数组")
                }
                objects = records
            }
            let events = objects.compactMap { object -> UsageEvent? in
                guard let time = JSONField.date(object["timestamp"] ?? object["created_at"] ?? object["createdAt"]),
                      let model = JSONField.text(object, "model") ?? JSONField.text(object, "model_name") else { return nil }
                func count(_ keys: [String]) -> Int64 {
                    guard let value = keys.lazy.compactMap({ JSONField.number(object, $0) }).first,
                          value >= 0, value <= Decimal(Int64.max / 8) else { return 0 }
                    return NSDecimalNumber(decimal: value).int64Value
                }
                let input = count(["input_tokens", "inputTokens"])
                let output = count(["output_tokens", "outputTokens"])
                let read = count(["cache_read_tokens", "cache_read_input_tokens"])
                let write = count(["cache_creation_tokens", "cache_creation_input_tokens"])
                let request = JSONField.text(object, "request_id") ?? JSONField.text(object, "id")
                    ?? "\(time.timeIntervalSince1970)|\(model)|\(input)|\(output)|\(read)|\(write)"
                return UsageEvent(id: eventID(tool: "cc-switch", session: accountID.uuidString, request: request), timestamp: time,
                    tool: JSONField.text(object, "tool") ?? JSONField.text(object, "app_type") ?? JSONField.text(object, "appType") ?? "cc-switch", accountID: accountID, model: model, inputTokens: input, outputTokens: output,
                    cacheReadTokens: read, cacheWriteTokens: write,
                    cost: JSONField.number(object, "cost") ?? JSONField.number(object, "cost_usd") ?? JSONField.number(object, "total_cost") ?? JSONField.number(object, "total_cost_usd"),
                    currency: JSONField.text(object, "currency") ?? "USD", origin: .integration, dataset: .imported)
            }
            guard objects.isEmpty || !events.isEmpty else { throw MonitorError.message("导出记录缺少可识别的时间或模型字段") }
            return events
        }.value
    }

    static func csv(_ text: String) -> [[String]] {
        var iterator = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).unicodeScalars.makeIterator()
        var result: [[String]] = [], row: [String] = []
        var field = "", quoted = false
        var current = iterator.next()
        while let char = current {
            current = iterator.next()
            if char == "\"" {
                if quoted && current == "\"" { field.append("\""); current = iterator.next() }
                else { quoted.toggle() }
            } else if char == "," && !quoted { row.append(field); field = "" }
            else if (char == "\n" || char == "\r") && !quoted {
                row.append(field); field = ""
                if !row.allSatisfy(\.isEmpty) { result.append(row) }; row = []
                if char == "\r" && current == "\n" { current = iterator.next() }
            } else { field.unicodeScalars.append(char) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); result.append(row) }
        return result
    }
}
