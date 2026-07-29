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
        let previous = snapshot(remainingPercent: 24, resetsAt: now.addingTimeInterval(300), fetchedAt: now)
        let current = snapshot(
            remainingPercent: 94,
            resetsAt: now.addingTimeInterval(7 * 24 * 3_600),
            fetchedAt: now.addingTimeInterval(300)
        )

        let event = try XCTUnwrap(QuotaResetDetector.detect(previous: previous, current: current))
        XCTAssertEqual(event.previousRemainingPercent, 24)
        XCTAssertEqual(event.currentRemainingPercent, 94)
        XCTAssertEqual(event.detectedAt, current.fetchedAt)
    }

    func testQuotaResetIsNotDetectedFromFirstOrDecreasingSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nearFull = snapshot(remainingPercent: 96, resetsAt: nil, fetchedAt: now)
        let decreased = snapshot(remainingPercent: 95, resetsAt: nil, fetchedAt: now.addingTimeInterval(300))

        XCTAssertNil(QuotaResetDetector.detect(previous: nil, current: nearFull))
        XCTAssertNil(QuotaResetDetector.detect(previous: nearFull, current: decreased))
    }

    func testQuotaResetIgnoresSmallNearFullCorrectionWithinSameWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetAt = now.addingTimeInterval(3_600)
        let previous = snapshot(remainingPercent: 94, resetsAt: resetAt, fetchedAt: now)
        let corrected = snapshot(
            remainingPercent: 96,
            resetsAt: resetAt,
            fetchedAt: now.addingTimeInterval(300)
        )

        XCTAssertNil(QuotaResetDetector.detect(previous: previous, current: corrected))
    }

    func testQuotaResetDetectedWhenRemainingReachesExactlyFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = snapshot(remainingPercent: 99, resetsAt: nil, fetchedAt: now)
        let current = snapshot(
            remainingPercent: 100,
            resetsAt: nil,
            fetchedAt: now.addingTimeInterval(300)
        )

        XCTAssertNotNil(QuotaResetDetector.detect(previous: previous, current: current))
    }

    func testQuotaResetDetectedWhenResetWindowAdvancesWhileAlreadyNearFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = snapshot(
            remainingPercent: 94,
            resetsAt: now.addingTimeInterval(300),
            fetchedAt: now
        )
        let current = snapshot(
            remainingPercent: 96,
            resetsAt: now.addingTimeInterval(7 * 24 * 3_600),
            fetchedAt: now.addingTimeInterval(300)
        )

        XCTAssertNotNil(QuotaResetDetector.detect(previous: previous, current: current))
    }

    func testEdgePathTrimmingUsesPathLength() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 100, y: 0))

        XCTAssertTrue(EdgePathTrimmer.trim(path, fraction: 0).isEmpty)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 0.52).currentPoint.x, 52, accuracy: 0.001)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 1).currentPoint.x, 100, accuracy: 0.001)
    }

    private func snapshot(
        remainingPercent: Int,
        resetsAt: Date?,
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            plan: "plus",
            main: RateBucket(
                id: "codex",
                name: "Codex",
                primary: RateWindow(
                    usedPercent: 100 - remainingPercent,
                    durationMinutes: 10_080,
                    resetsAt: resetsAt
                ),
                secondary: nil
            ),
            buckets: [],
            resetCreditCount: nil,
            resetCredits: [],
            fetchedAt: fetchedAt
        )
    }
}
