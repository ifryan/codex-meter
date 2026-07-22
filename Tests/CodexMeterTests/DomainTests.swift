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

    func testEdgePathTrimmingUsesPathLength() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 100, y: 0))

        XCTAssertTrue(EdgePathTrimmer.trim(path, fraction: 0).isEmpty)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 0.52).currentPoint.x, 52, accuracy: 0.001)
        XCTAssertEqual(EdgePathTrimmer.trim(path, fraction: 1).currentPoint.x, 100, accuracy: 0.001)
    }
}
