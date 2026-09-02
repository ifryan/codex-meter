// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import XCTest
@testable import CodexMeter

final class DomainTests: XCTestCase {
    func testRemainingPercentIsClamped() {
        XCTAssertEqual(RateWindow(usedPercent: 48, durationMinutes: nil, resetsAt: nil).remainingPercent, 52)
        XCTAssertEqual(RateWindow(usedPercent: -20, durationMinutes: nil, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(RateWindow(usedPercent: 120, durationMinutes: nil, resetsAt: nil).remainingPercent, 0)
    }

    func testCompactTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CompactTimeFormatter.text(until: now.addingTimeInterval(60), now: now), "1M")
        XCTAssertEqual(CompactTimeFormatter.text(until: now.addingTimeInterval(3_600), now: now), "1H")
        XCTAssertEqual(CompactTimeFormatter.text(until: now.addingTimeInterval(86_400), now: now), "24H")
        XCTAssertEqual(CompactTimeFormatter.text(until: now.addingTimeInterval(86_401), now: now), "2D")
    }

    func testTypedRateLimitParsing() throws {
        let payload = #"""
        {
          "rateLimits": {
            "limitId": "codex",
            "planType": "plus",
            "primary": {"usedPercent": 48, "windowDurationMins": 10080, "resetsAt": 2000000},
            "secondary": null
          },
          "rateLimitsByLimitId": {
            "codex-mini": {"limitId": "codex-mini", "limitName": "Mini", "primary": {"usedPercent": 20}}
          },
          "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [{"expiresAt": 2100000}]
          }
        }
        """#.data(using: .utf8)!

        let snapshot = try CodexUsageParser().parse(resultData: payload, fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.main.primary?.remainingPercent, 52)
        XCTAssertEqual(snapshot.buckets.first?.name, "Mini")
        XCTAssertEqual(snapshot.resetCreditCount, 2)
        XCTAssertEqual(snapshot.resetCredits.count, 1)
    }

    func testQuotaResetDetectedWhenRemainingReturnsNearFull() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = window(remainingPercent: 24, resetsAt: now.addingTimeInterval(300))
        let current = window(remainingPercent: 94, resetsAt: now.addingTimeInterval(7 * 24 * 3_600))
        let detectedAt = now.addingTimeInterval(300)

        let event = try XCTUnwrap(QuotaResetDetector.detect(previous: previous, current: current, at: detectedAt))
        XCTAssertEqual(event.previousRemainingPercent, 24)
        XCTAssertEqual(event.currentRemainingPercent, 94)
        XCTAssertEqual(event.detectedAt, detectedAt)
    }

    func testQuotaResetIsNotDetectedFromFirstOrDecreasingSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nearFull = window(remainingPercent: 96, resetsAt: nil)
        let decreased = window(remainingPercent: 95, resetsAt: nil)

        XCTAssertNil(QuotaResetDetector.detect(previous: nil, current: nearFull, at: now))
        XCTAssertNil(QuotaResetDetector.detect(previous: nearFull, current: decreased, at: now.addingTimeInterval(300)))
    }

    func testQuotaResetIgnoresSmallNearFullCorrectionWithinSameWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetAt = now.addingTimeInterval(3_600)
        let previous = window(remainingPercent: 94, resetsAt: resetAt)
        let corrected = window(remainingPercent: 96, resetsAt: resetAt)

        XCTAssertNil(QuotaResetDetector.detect(previous: previous, current: corrected, at: now.addingTimeInterval(300)))
    }

    func testQuotaResetDetectedWhenRemainingReachesExactlyFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = window(remainingPercent: 99, resetsAt: nil)
        let current = window(remainingPercent: 100, resetsAt: nil)

        XCTAssertNotNil(QuotaResetDetector.detect(previous: previous, current: current, at: now.addingTimeInterval(300)))
    }

    func testQuotaResetDetectedWhenResetWindowAdvancesWhileAlreadyNearFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = window(remainingPercent: 94, resetsAt: now.addingTimeInterval(300))
        let current = window(remainingPercent: 96, resetsAt: now.addingTimeInterval(7 * 24 * 3_600))

        XCTAssertNotNil(QuotaResetDetector.detect(previous: previous, current: current, at: now.addingTimeInterval(300)))
    }

    func testEdgePathTrimmingUsesPathLength() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 100, y: 0))

        XCTAssertTrue(EdgePathTrimmer.trim(path, fraction: 0).isEmpty)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 0.52).currentPoint.x, 52, accuracy: 0.001)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 1).currentPoint.x, 100, accuracy: 0.001)
    }

    /// Matches an actual captured response from `GET /api/oauth/usage`: `utilization` is a
    /// 0-100 number, `resets_at` is an ISO-8601 string (not a Unix timestamp) — the exact
    /// shape mismatch that originally produced a garbage "95043D" countdown.
    func testClaudeUsageParserParsesRealResponseShape() throws {
        let payload = #"""
        {
          "five_hour": {"utilization": 24.0, "resets_at": "2026-09-02T06:50:00.427202+00:00", "limit_dollars": null},
          "seven_day": {"utilization": 3.0, "resets_at": "2026-09-03T07:00:00.427225+00:00", "limit_dollars": null}
        }
        """#.data(using: .utf8)!

        let snapshot = try ClaudeUsageParser().parse(data: payload, capturedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 24)
        let expectedResetsAt = Date(timeIntervalSince1970: 1_788_331_800.427202)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0, expectedResetsAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 3)
    }

    func testClaudeUsageParserToleratesUsedPercentageFieldName() throws {
        let payload = #"""
        {"five_hour": {"used_percentage": 5, "resets_at": "2026-09-02T06:50:00+00:00"}}
        """#.data(using: .utf8)!

        let snapshot = try ClaudeUsageParser().parse(data: payload)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 5)
        XCTAssertNil(snapshot.sevenDay)
    }

    func testClaudeUsageParserScalesFractionToPercent() throws {
        let payload = #"""
        {"five_hour": {"utilization": 0.284, "resets_at": "2026-09-02T06:50:00+00:00"}}
        """#.data(using: .utf8)!

        let snapshot = try ClaudeUsageParser().parse(data: payload)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 28)
    }

    func testClaudeUsageParserToleratesMissingWindows() throws {
        let payload = "{}".data(using: .utf8)!
        let snapshot = try ClaudeUsageParser().parse(data: payload)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay)
    }

    func testClaudeUsageParserRejectsUnparseableResponse() {
        let payload = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeUsageParser().parse(data: payload))
    }

    func testClaudeTightestWindowPicksLowestRemaining() {
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: RateWindow(usedPercent: 80, durationMinutes: nil, resetsAt: nil),
            sevenDay: RateWindow(usedPercent: 20, durationMinutes: nil, resetsAt: nil),
            capturedAt: Date()
        )
        XCTAssertEqual(snapshot.tightest?.usedPercent, 80)
    }

    func testDetailRowBuilderWindowRow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = RateWindow(usedPercent: 28, durationMinutes: nil, resetsAt: now.addingTimeInterval(3_600))
        let row = DetailRowBuilder.windowRow(title: "Claude 5H", window: window, now: now)
        XCTAssertEqual(row.title, "Claude 5H")
        XCTAssertEqual(row.value, "剩余 72% · 1H")
    }

    func testDetailRowBuilderMissingWindow() {
        let row = DetailRowBuilder.windowRow(title: "Claude 5H", window: nil)
        XCTAssertEqual(row.value, "暂无额度窗口")
    }

    func testMeterValueText() {
        XCTAssertEqual(MeterValue(percent: 52, resetText: "3H").text, "52% 3H")
    }

    private func window(remainingPercent: Int, resetsAt: Date?) -> RateWindow {
        RateWindow(usedPercent: 100 - remainingPercent, durationMinutes: 10_080, resetsAt: resetsAt)
    }
}
