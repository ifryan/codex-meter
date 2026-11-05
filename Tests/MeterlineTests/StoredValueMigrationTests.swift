// SPDX-License-Identifier: GPL-3.0-only
import SQLite3
import XCTest
@testable import Meterline

final class StoredValueMigrationTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func rows(_ sql: String) throws -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
        return result
    }

    private func createVersion2Database() throws {
        let columns = "time,tool,account,model,input,output,cache_read,cache_write,cost,currency,origin,price_version,dataset"
        try execute("""
        CREATE TABLE events (id TEXT PRIMARY KEY, time REAL NOT NULL, tool TEXT NOT NULL, account TEXT, model TEXT NOT NULL,
          input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
          cost TEXT, currency TEXT NOT NULL, origin TEXT NOT NULL, price_version TEXT, dataset TEXT NOT NULL DEFAULT 'local');
        CREATE TABLE snapshots (account TEXT NOT NULL, slot INTEGER NOT NULL, time REAL NOT NULL, data BLOB NOT NULL, PRIMARY KEY(account,slot));
        CREATE TABLE cursors (path TEXT PRIMARY KEY, data BLOB NOT NULL);
        INSERT INTO events (id,\(columns)) VALUES
          ('provider:a:r:cost:1:组织账单（未按模型拆分）:||:USD',1,'openai-api','a','组织账单（未按模型拆分）',0,0,0,0,'5','USD','provider',NULL,'provider'),
          ('provider:a:r:tokens:1:组织用量（未按模型拆分）:||',1,'openai-api','a','组织用量（未按模型拆分）',1,1,0,0,NULL,'USD','provider',NULL,'provider'),
          ('log:1',1,'codex',NULL,'gpt-5',1,1,0,0,'1','USD','estimate','手工更新 / 2026-01-01T00:00:00Z','local'),
          ('log:2',1,'pi',NULL,'gpt-5',1,1,0,0,'1','USD','localLog','日志中的价格估算','local');
        INSERT INTO snapshots VALUES ('a',0,1,CAST('{"metrics":[{"id":"额度.current_interval","unit":"次"},{"id":"额度 2","unit":"%"}]}' AS BLOB));
        PRAGMA user_version=2;
        """)
    }

    func testVersion2DatabaseMovesToEnglishValues() throws {
        try createVersion2Database()
        _ = try UsageHistory(url: url)
        XCTAssertEqual(try rows("PRAGMA user_version"), ["3"])
        XCTAssertEqual(try rows("SELECT id FROM events WHERE tool='openai-api' ORDER BY id"), [
            "provider:a:r:cost:1:Organization bill (not split by model):||:USD",
            "provider:a:r:tokens:1:Organization usage (not split by model):||"
        ])
        XCTAssertEqual(try rows("SELECT price_version FROM events WHERE id='log:1'"), ["manual / 2026-01-01T00:00:00Z"])
        XCTAssertEqual(try rows("SELECT price_version FROM events WHERE id='log:2'"), ["log price estimate"])
        XCTAssertEqual(try rows("SELECT CAST(data AS TEXT) FROM snapshots"),
                       [#"{"metrics":[{"id":"quota.current_interval","unit":"uses"},{"id":"quota-2","unit":"%"}]}"#])
        XCTAssertEqual(try rows("SELECT count(*) FROM events WHERE model GLOB '*[一-龥]*' OR id GLOB '*[一-龥]*'"), ["0"])
    }

    func testBillingRefreshAfterMigrationUpdatesTheSameRow() async throws {
        try createVersion2Database()
        let history = try UsageHistory(url: url)
        let event = UsageEvent(id: "provider:a:r:cost:1:\(StoredLabel.organizationBill):||:USD", timestamp: Date(timeIntervalSince1970: 1),
                               tool: "openai-api", accountID: nil, model: StoredLabel.organizationBill, cost: 7, origin: .provider, dataset: .provider)
        try await history.insert([event])
        XCTAssertEqual(try rows("SELECT cost FROM events WHERE tool='openai-api' AND cost IS NOT NULL"), ["7"])
    }

    func testMigrationRunsOnce() throws {
        try createVersion2Database()
        _ = try UsageHistory(url: url)
        try execute("UPDATE events SET price_version='手工更新 / kept' WHERE id='log:1'")
        _ = try UsageHistory(url: url)
        XCTAssertEqual(try rows("SELECT price_version FROM events WHERE id='log:1'"), ["手工更新 / kept"])
    }

    func testConfigurationUpgradesSavedChineseValues() {
        var account = SourceAccount(sourceID: "custom", name: "Mine")
        account.primaryMetricID = "额度.current_weekly"
        account.custom = CustomQuery(url: "https://example.com", mappings: [.init(title: "Pool", kind: .quota, valuePath: "a", unit: "次")])
        var other = SourceAccount(sourceID: "gemini", name: "G")
        other.primaryMetricID = "额度 3"
        var config = MonitorConfiguration(accounts: [account, other])
        config.prices = [ModelPrice(model: "m", inputPerMillion: 1, outputPerMillion: 1, version: "手工更新 / 2026")]
        config.normalize()
        XCTAssertEqual(config.accounts[0].primaryMetricID, "quota.current_weekly")
        XCTAssertEqual(config.accounts[0].custom?.mappings[0].unit, "uses")
        XCTAssertEqual(config.accounts[1].primaryMetricID, "quota-3")
        XCTAssertEqual(config.prices[0].version, "manual / 2026")
    }
}
