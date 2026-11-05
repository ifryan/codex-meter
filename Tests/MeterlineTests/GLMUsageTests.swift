// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
@testable import Meterline

final class GLMUsageTests: XCTestCase {
    private static let payload = Data(#"{"success":true,"data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":70,"nextResetTime":1800000000000},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":20,"nextResetTime":1800100000000},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":99}]}}"#.utf8)

    func testCreditWindowsAndMonthlyMCP() throws {
        let date = Date(timeIntervalSince1970: 10)
        let result = try GLMUsageParser().parse(data: Self.payload, capturedAt: date)
        XCTAssertEqual(result.plan, "pro")
        XCTAssertEqual(result.capturedAt, date)
        XCTAssertEqual(result.fiveHour?.remainingPercent, 30)
        XCTAssertEqual(result.sevenDay?.remainingPercent, 80)
        XCTAssertEqual(result.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.tightest, result.fiveHour)
        XCTAssertEqual(result.quotas.last?.isMCP, true)
        XCTAssertNil(result.quotas.last?.window.durationMinutes)
        XCTAssertEqual(result.quotas.count, 3)
    }

    func testLegacyAndMissingReset() throws {
        let data = Data(#"{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.5}]}}"#.utf8)
        let result = try GLMUsageParser().parse(data: data)
        XCTAssertEqual(result.fiveHour?.remainingPercent, 87)
        XCTAssertNil(result.fiveHour?.resetsAt)
        XCTAssertNil(result.sevenDay)
    }

    func testUnknownPeriodDoesNotInventFiveHours() throws {
        let data = Data(#"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":99,"percentage":60,"nextResetTime":1800000000},{"type":"TOKENS_LIMIT","percentage":20}]}}"#.utf8)
        let result = try GLMUsageParser().parse(data: data)
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(result.sevenDay)
        XCTAssertNil(result.tightest?.durationMinutes)
        XCTAssertTrue(result.quotas.allSatisfy { $0.label.contains("Unknown period") })
        XCTAssertEqual(result.tightest?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testAbsoluteAmountsNumericStringsAndPercentageScale() throws {
        let data = Data(#"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":"3","number":"5","usage":"200","currentValue":"50"},{"type":"CREDIT_LIMIT","unit":6,"percentage":0.5},{"type":"TIME_LIMIT","unit":5,"usage":100,"remaining":20}]}}"#.utf8)
        let result = try GLMUsageParser().parse(data: data)
        XCTAssertEqual(result.fiveHour?.usedPercent, 25)
        // GLM percentage is 0–100, never a utilization fraction.
        XCTAssertEqual(result.sevenDay?.usedPercent, 1)
        XCTAssertEqual(result.quotas.last?.window.usedPercent, 80)
    }

    func testMalformedOrEmptyPayloadIsNotZeroUsage() {
        for text in ["not json", "{}", #"{"success":false,"data":{"limits":[]}}"#,
                     #"{"success":true,"data":{"limits":[]}}"#,
                     #"{"success":true,"data":{"limits":[{"type":"TIME_LIMIT","percentage":0}]}}"#,
                     #"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","percentage":true}]}}"#,
                     #"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","percentage":"NaN","usage":0}]}}"#] {
            XCTAssertThrowsError(try GLMUsageParser().parse(data: Data(text.utf8)))
        }
    }

    func testInvalidRowsDoNotHideOtherValidWindows() throws {
        let data = Data(#"{"success":true,"data":{"limits":[{"type":"FUTURE_LIMIT","percentage":90},{"type":"CREDIT_LIMIT"},{"type":"CREDIT_LIMIT","unit":6,"percentage":150,"nextResetTime":-1}]}}"#.utf8)
        let result = try GLMUsageParser().parse(data: data)
        XCTAssertEqual(result.quotas.count, 1)
        XCTAssertEqual(result.sevenDay?.remainingPercent, 0)
        XCTAssertNil(result.sevenDay?.resetsAt)
    }

    func testTiesSelectShorterPeriodAcrossProviders() {
        let weekly = RateWindow(usedPercent: 50, durationMinutes: 10_080, resetsAt: nil)
        let short = RateWindow(usedPercent: 50, durationMinutes: 300, resetsAt: nil)
        XCTAssertEqual(RateWindow.tightest([weekly, short]), short)
        let weeklyValue = MeterValue(percent: 50, resetText: "3D", durationMinutes: 10_080)
        let shortValue = MeterValue(percent: 50, resetText: "2H", durationMinutes: 300)
        XCTAssertEqual(MeterValue.tightest([weeklyValue, shortValue]), shortValue)
    }

    func testKeyValidationDoesNotAllowHeaderInjection() throws {
        XCTAssertEqual(try GLMCredentialsStore.validated("  synthetic-key\n"), "synthetic-key")
        for key in ["", " \n", "key\r\nInjected: value", "a b", "密钥", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try GLMCredentialsStore.validated(key))
        }
    }

    func testRequestUsesFixedMonitorAndRawAuthorization() async throws {
        let client = GLMUsageClient(readKey: { "synthetic-key" }, transport: { request in
            XCTAssertEqual(request.url, GLMUsageClient.endpoint)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "synthetic-key")
            XCTAssertNil(request.httpBody)
            return (Self.payload, HTTPURLResponse(url: GLMUsageClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await client.fetch()
        XCTAssertEqual(result.tightest?.remainingPercent, 30)
    }

    func testUnconfiguredAndInaccessibleCredentialsNeverRequest() async {
        let missing = GLMUsageClient(readKey: { nil }, transport: { _ in
            XCTFail("No network request without a credential")
            throw URLError(.badURL)
        })
        do { _ = try await missing.fetch(); XCTFail("Expected not configured") }
        catch { XCTAssertEqual(error as? GLMError, .notConfigured) }
        let locked = GLMUsageClient(readKey: { throw GLMError.keychainUnavailable }, transport: { _ in
            XCTFail("No network request when Keychain is inaccessible")
            throw URLError(.badURL)
        })
        do { _ = try await locked.fetch(); XCTFail("Expected Keychain error") }
        catch { XCTAssertEqual(error as? GLMError, .keychainUnavailable) }
    }

    func testHTTPFailuresAndTimeoutAreSanitized() async {
        for (status, expected) in [(401, GLMError.unauthorized), (403, .unauthorized), (429, .rateLimited), (503, .server(503)), (302, .server(302))] {
            let client = GLMUsageClient(readKey: { "synthetic-key" }, transport: { _ in
                (Data("sensitive-server-error".utf8), HTTPURLResponse(url: GLMUsageClient.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await client.fetch(); XCTFail("Expected HTTP failure") }
            catch {
                XCTAssertEqual(error as? GLMError, expected)
                XCTAssertFalse(error.localizedDescription.contains("sensitive-server-error"))
            }
        }
        let client = GLMUsageClient(readKey: { "synthetic-key" }, transport: { _ in throw URLError(.timedOut) })
        do { _ = try await client.fetch(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? GLMError, .timedOut) }
    }

    func testSuccessfulHTTPWithInvalidBodyFails() async {
        let client = GLMUsageClient(readKey: { "synthetic-key" }, transport: { _ in
            (Data("<html>login</html>".utf8), HTTPURLResponse(url: GLMUsageClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await client.fetch(); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? GLMError, .invalidResponse) }
    }

    func testStackedRowsAlignAcrossNotchAndCapsule() {
        let wings = MeterLayout.wingRects(width: 364, top: 32, height: 32, notch: NSRange(location: 112, length: 180))
        XCTAssertEqual(wings.count, 2)
        XCTAssertEqual(wings[0].maxX, 112)
        XCTAssertEqual(wings[1].minX, 292)
        XCTAssertEqual(wings[1].maxX, 364)
        for physicalHeight in [CGFloat(24), CGFloat(32), CGFloat(37.5)] {
            let height = MeterLayout.headerHeight(notchHeight: physicalHeight)
            XCTAssertLessThanOrEqual(height, physicalHeight)
            for notch in [NSRange(location: 112, length: 180), nil] {
                let pair = MeterLayout.wingRects(width: 364, top: height, height: height, notch: notch)
                let left = MeterLayout.rows(in: pair[0])
                let right = MeterLayout.rows(in: pair[1])
                XCTAssertEqual(left.count, 3)
                XCTAssertEqual(left.map(\.midY), right.map(\.midY))
                XCTAssertGreaterThan(left[0].minY, left[1].minY)
                XCTAssertGreaterThan(left[1].minY, left[2].minY)
                XCTAssertTrue(left.allSatisfy { pair[0].contains($0) })
                XCTAssertTrue(right.allSatisfy { pair[1].contains($0) })
            }
        }
    }

    func testDisplayPrefersFiveHoursEvenWhenWeeklyQuotaIsLower() {
        let fiveHour = RateWindow(usedPercent: 10, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 200))
        let weekly = RateWindow(usedPercent: 95, durationMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(RateWindow.displayWindow([weekly, fiveHour]), fiveHour)
        XCTAssertEqual(RateWindow.displayWindow([weekly]), weekly)
        XCTAssertNil(RateWindow.displayWindow([RateWindow(usedPercent: 1, durationMinutes: nil, resetsAt: nil)]))
        XCTAssertNil(RateWindow.displayWindow([]))
    }

    @MainActor
    func testGLMAccessibilityAndExpandableDetails() {
        let view = NotchMeterView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        view.setGLM(value: MeterValue(percent: 31, resetText: "2H"))
        XCTAssertTrue(view.accessibilityLabel()?.contains("GLM 31% left") == true)
        view.setGLM(value: nil, isConfigured: false)
        XCTAssertTrue(view.accessibilityLabel()?.contains("GLM not configured") == true)
        view.setDetailSections([MeterDetailSection(agent: .glm, plan: "PRO", rows: [MeterDetailRow(title: "5H", value: "剩余 31% · 2H")])])
        let shortHeight = view.detailHeight(width: 344)
        view.setDetailSections([MeterDetailSection(agent: .glm, plan: "PRO", rows: (0..<20).map { MeterDetailRow(title: "额度 \($0)", value: "剩余 31% · 2H") })])
        XCTAssertGreaterThan(view.detailHeight(width: 344), shortHeight)
    }
}

/// Deliberately ignores task cancellation, like a transport completing after a credential change.
@MainActor
private final class SuspendedFetch {
    private var continuation: CheckedContinuation<Int, Error>?
    let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }
    func fetch() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish(_ value: Int) { continuation?.resume(returning: value); continuation = nil }
}

final class UsageLoaderTests: XCTestCase {
    @MainActor
    func testThreeProvidersFinishIndependentlyAndDeduplicate() async throws {
        let started = expectation(description: "Slow provider started")
        let gate = SuspendedFetch(started: started)
        let codex = UsageLoader<Int>()
        let claude = UsageLoader<Int>()
        let glm = UsageLoader<Int>()
        let slow = try XCTUnwrap(claude.refresh(fetch: { try await gate.fetch() }))
        let fast = try XCTUnwrap(codex.refresh(fetch: { 52 }))
        let third = try XCTUnwrap(glm.refresh(fetch: { 30 }))
        await fulfillment(of: [started], timeout: 1)
        await fast.value
        await third.value
        XCTAssertEqual(codex.snapshot, 52)
        XCTAssertEqual(glm.snapshot, 30)
        XCTAssertTrue(claude.isLoading)
        XCTAssertNil(claude.refresh(fetch: { XCTFail("Duplicate fetch"); return 0 }))
        gate.finish(80)
        await slow.value
        XCTAssertEqual(claude.snapshot, 80)
        XCTAssertFalse(claude.isLoading)
    }

    @MainActor
    func testReplacingCredentialsDiscardsOldResultAndResetBaseline() async throws {
        let started = expectation(description: "Old credential request started")
        let gate = SuspendedFetch(started: started)
        let loader = UsageLoader<Int>()
        loader.seed(10)
        let old = try XCTUnwrap(loader.refresh(fetch: { try await gate.fetch() }, onSuccess: { _, _ in XCTFail("Old result accepted") }))
        await fulfillment(of: [started], timeout: 1)
        loader.invalidate()
        XCTAssertNil(loader.snapshot)
        let fresh = try XCTUnwrap(loader.refresh(fetch: { 100 }, onSuccess: { previous, _ in XCTAssertNil(previous) }))
        await fresh.value
        gate.finish(20)
        await old.value
        XCTAssertEqual(loader.snapshot, 100)
        XCTAssertNil(loader.error)
    }

    @MainActor
    func testRemovingCredentialsDoesNotResurrectOldSnapshot() async throws {
        let started = expectation(description: "Request started")
        let gate = SuspendedFetch(started: started)
        let loader = UsageLoader<Int>()
        let old = try XCTUnwrap(loader.refresh(fetch: { try await gate.fetch() }))
        await fulfillment(of: [started], timeout: 1)
        loader.invalidate()
        let removed = try XCTUnwrap(loader.refresh(fetch: { throw GLMError.notConfigured }))
        await removed.value
        gate.finish(55)
        await old.value
        XCTAssertNil(loader.snapshot)
        XCTAssertEqual(loader.error as? GLMError, .notConfigured)
        XCTAssertFalse(loader.isLoading)
    }

    @MainActor
    func testFailureRetainsSnapshotAndFirstSuccessDoesNotNotify() async throws {
        let loader = UsageLoader<RateWindow>()
        let first = try XCTUnwrap(loader.refresh(fetch: {
            RateWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil)
        }, onSuccess: { previous, current in
            XCTAssertNil(QuotaResetDetector.detect(previous: previous, current: current, at: Date()))
        }))
        await first.value
        let failed = try XCTUnwrap(loader.refresh(fetch: { throw GLMError.timedOut }))
        await failed.value
        XCTAssertEqual(loader.snapshot?.remainingPercent, 100)
        XCTAssertEqual(loader.error as? GLMError, .timedOut)
        XCTAssertFalse(loader.isLoading)
    }

    @MainActor
    func testCancellationAllowsTheNextRefresh() async throws {
        let started = expectation(description: "Cancellable request started")
        let gate = SuspendedFetch(started: started)
        let loader = UsageLoader<Int>()
        loader.seed(42)
        let request = try XCTUnwrap(loader.refresh(fetch: { try await gate.fetch() }))
        await fulfillment(of: [started], timeout: 1)
        request.cancel()
        gate.finish(99)
        await request.value
        XCTAssertEqual(loader.snapshot, 42)
        XCTAssertFalse(loader.isLoading)
        let retry = try XCTUnwrap(loader.refresh(fetch: { 50 }))
        await retry.value
        XCTAssertEqual(loader.snapshot, 50)
    }
}
