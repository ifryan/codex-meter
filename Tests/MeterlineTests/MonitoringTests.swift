// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Meterline

final class MonitoringTests: XCTestCase {
    func testMappingPreservesUnitsArraysAndUnknownFields() throws {
        let root: [String: Any] = ["data": ["pools": [
            ["name": "daily", "used": "25", "limit": 100, "reset": 1_800_000_000_000],
            ["name": "missing", "limit": 100]
        ]]]
        let mapping = MetricMapping(id: "pool", title: "额度", kind: .quota, valuePath: "used", unit: "次",
            totalPath: "limit", resetPath: "reset", rowsPath: "data.pools", labelPath: "name", mode: .used)
        let metrics = mapping.extract(root)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].title, "daily")
        XCTAssertEqual(metrics[0].value, 75)
        XCTAssertEqual(metrics[0].remainingPercent, 75)
        XCTAssertEqual(metrics[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(metrics[0].durationMinutes)
        XCTAssertNil(JSONField.decimal(true))
        XCTAssertNil(JSONField.decimal("12 invalid"))
        XCTAssertNil(JSONField.value(root, at: "data.pools[20]"))
    }

    func testCustomRequestsKeepCredentialsOutOfExportedTemplate() throws {
        let query = CustomQuery(url: "https://example.com/usage", mappings: [.init(title: "余额", kind: .balance, valuePath: "balance", unit: "USD")])
        let request = try query.request(secrets: ["token": "test-only-not-a-real-key"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-not-a-real-key")
        let template = ConnectionTemplate(sourceID: "custom", name: "测试", endpoint: "", custom: query)
        let encoded = String(decoding: try JSONEncoder().encode(template), as: UTF8.self)
        XCTAssertFalse(encoded.contains("test-only-not-a-real-key"))
        XCTAssertTrue(encoded.contains("${token}"))
        var invalid = query
        invalid.headers["Authorization"] = "Bearer unsafe-literal"
        XCTAssertThrowsError(try invalid.validate())
        invalid = query; invalid.url = "http://example.com/usage"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testNativeMiniMaxUnlimitedAndExhaustedWindowsAreDifferent() throws {
        let root: [String: Any] = ["base_resp": ["status_code": 0], "model_remains": [
            ["model_name": "general", "current_interval_status": 2, "current_interval_remaining_percent": 90,
             "current_weekly_status": 3, "current_weekly_remaining_percent": 100]
        ]]
        let metrics = try NativeMetrics.parse(root, source: "minimax")
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.remainingPercent, 0)
        XCTAssertNil(metrics.first?.durationMinutes)
    }

    func testKimiReadsCountedWeeklyAndFiveHourWindows() throws {
        let root: [String: Any] = [
            "usage": ["limit": "100", "used": "12"],
            "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"], "detail": ["limit": 100, "remaining": 72]]]
        ]
        let metrics = try NativeMetrics.parse(root, source: "kimi")
        XCTAssertEqual(metrics.first(where: { $0.durationMinutes == 300 })?.remainingPercent, 72)
        XCTAssertEqual(metrics.first(where: { $0.durationMinutes == 10_080 })?.remainingPercent, 88)
    }

    func testRegistryAndAccountNormalizationKeepInstancesSeparate() {
        XCTAssertEqual(Set(SourceRegistry.all.map(\.id)).count, SourceRegistry.all.count)
        var configuration = MonitorConfiguration(accounts: (0..<5).map {
            SourceAccount(sourceID: "openrouter", name: "账户 \($0)", pinned: true)
        })
        configuration.accounts[1].enabled = false
        configuration.normalize()
        XCTAssertEqual(configuration.accounts.filter(\.pinned).count, 3)
        XCTAssertEqual(Set(configuration.accounts.map(\.id)).count, 5)
        XCTAssertFalse(configuration.accounts[1].pinned)
        XCTAssertNotEqual(configuration.accounts[0].credentialRevision, configuration.accounts[2].credentialRevision)
    }

    func testUnknownCachePricingDoesNotFabricateZeroCost() {
        let price = ModelPrice(model: "example-model", inputPerMillion: 2, outputPerMillion: 10, version: "test-v1")
        var event = UsageEvent(id: "one", timestamp: Date(), tool: "claude", model: "example-model", inputTokens: 1_000_000,
                               outputTokens: 100_000, cacheReadTokens: 100)
        event.price(using: [price])
        XCTAssertNil(event.cost)
        event.cacheReadTokens = 0
        event.price(using: [price])
        XCTAssertEqual(event.cost, 3)
        XCTAssertEqual(event.origin, .estimate)
        XCTAssertEqual(event.priceVersion, "test-v1")
    }

    func testCodexCumulativeCountersAreDeltaCountedAndCacheExclusive() {
        var cursor = LogCursor(session: "test-session", model: "example-model")
        let root: [String: Any] = ["type": "event_msg", "timestamp": "2026-10-27T02:00:00Z", "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 40]]
        ]]
        let event = UsageLogScanner.parse(root, tool: "codex", cursor: &cursor, account: nil)
        XCTAssertEqual(event?.inputTokens, 60)
        XCTAssertEqual(event?.cacheReadTokens, 40)
        XCTAssertEqual(event?.totalTokens, 120)
        XCTAssertNil(event?.accountID)
        XCTAssertNil(UsageLogScanner.parse(root, tool: "codex", cursor: &cursor, account: nil))
    }

    func testCSVHandlesQuotedFieldsAndCRLF() {
        XCTAssertEqual(UsageImport.csv("model,cost\r\n\"a,b\",1.5\r\n"), [["model", "cost"], ["a,b", "1.5"]])
    }

    func testCustomPreviewHidesValuesAndLabelsKeepArrayIDsStable() {
        let first: [String: Any] = ["name": "daily", "remaining": 50, "secret": "do-not-display"]
        let second: [String: Any] = ["name": "weekly", "remaining": 80]
        let query = MetricMapping(id: "pool", title: "窗口", kind: .quota, valuePath: "remaining", unit: "%",
                                  rowsPath: "pools", labelPath: "name", mode: .remainingPercent)
        let original = query.extract(["pools": [first, second]])
        let reordered = query.extract(["pools": [second, first]])
        XCTAssertEqual(original[0].id, reordered[1].id)
        XCTAssertEqual(original[1].id, reordered[0].id)
        let structure = JSONField.structure(["pools": [first, second]]).joined(separator: "\n")
        XCTAssertTrue(structure.contains("pools[0].remaining · number"))
        XCTAssertFalse(structure.contains("do-not-display"))
    }

    func testProviderBillsAcceptCorrectionsAndRespectCredentialScopes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appendingPathComponent("history.sqlite"))
        let account = UUID(), previousScope = UUID(), scope = UUID(), now = Date()
        var event = UsageEvent(id: "provider:\(account):\(scope):cost:day:USD", timestamp: now,
                               tool: "openai-api", accountID: account, model: "组织账单", cost: 10, origin: .provider, dataset: .provider)
        var old = event
        old.id = "provider:\(account):\(previousScope):cost:day:USD"; old.cost = 100
        try await history.insert([old, event])
        event.cost = 7
        try await history.insert([event])
        let report = try await history.report(days: 1, grouping: .account, dataset: .provider, activeProviderScopes: [account: scope], now: now)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.requests, 1)
        XCTAssertEqual(report.groups.first?.cost, 7)
    }

    func testHistoryDeduplicatesStreamingUpdatesAndSeparatesImportedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try UsageHistory(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        let account = UUID()
        var event = UsageEvent(id: "request-one", timestamp: now, tool: "claude", accountID: account, model: "example", inputTokens: 10, outputTokens: 1)
        try await history.insert([event, event])
        event.outputTokens = 8
        try await history.insert([event])
        var imported = event
        imported.id = "imported-one"; imported.tool = "cc-switch"; imported.origin = .integration
        imported.dataset = .imported
        try await history.insert([imported])
        let local = try await history.report(days: 1, grouping: .account, now: now)
        XCTAssertEqual(local.groups.count, 1)
        XCTAssertEqual(local.groups.first?.requests, 1)
        XCTAssertEqual(local.groups.first?.tokens, 18)
        XCTAssertEqual(local.groups.first?.unpriced, 1)
        let external = try await history.report(days: 1, grouping: .account, dataset: .imported, now: now)
        XCTAssertEqual(external.groups.first?.tokens, 18)
        XCTAssertEqual(external.groups.first?.requests, 1)
    }
}
