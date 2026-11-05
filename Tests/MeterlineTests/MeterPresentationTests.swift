// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
@testable import Meterline

final class MeterPresentationTests: XCTestCase {
    func testSavedOrderIgnoresUnknownAndDuplicateProviders() {
        XCTAssertEqual(MeterAgentOrder.normalized(["glm", "future", "glm", "codex"]), [.glm, .codex, .claude])
        XCTAssertEqual(MeterAgentOrder.normalized([]), [.codex, .claude, .glm])
        let moved = MeterAgentOrder.moving(.glm, to: 0, in: MeterAgent.allCases)
        XCTAssertEqual(moved, [.glm, .codex, .claude])
        XCTAssertEqual(MeterAgentOrder.normalized(moved.map(\.rawValue)), moved)
        XCTAssertEqual(MeterAgentOrder.moving(.glm, to: 2, in: moved), MeterAgent.allCases)
        XCTAssertEqual(MeterAgentOrder.moving(.claude, to: 1, in: MeterAgent.allCases), MeterAgent.allCases)
    }

    func testDualSummaryKeepsQuotaAndCountdownInSameOrder() {
        let now = Date(timeIntervalSince1970: 0)
        let fiveHour = RateWindow(usedPercent: 28, durationMinutes: 300, resetsAt: now.addingTimeInterval(7_200))
        let weekly = RateWindow(usedPercent: 12, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(345_600))
        let value = MeterValue.summary(windows: [weekly, fiveHour], now: now)
        XCTAssertEqual(value?.text, "72%/88% 2H/4D")
        XCTAssertEqual(value?.percent, 72)
        XCTAssertEqual(value?.secondaryPercent, 88)
        XCTAssertEqual(MeterValue.summary(windows: [weekly], now: now)?.text, "88% 4D")
        XCTAssertNil(MeterValue.summary(windows: [weekly], now: now)?.secondaryPercent)
        let unknownReset = RateWindow(usedPercent: 2, durationMinutes: 300, resetsAt: nil)
        XCTAssertEqual(MeterValue.summary(windows: [unknownReset, weekly], now: now)?.text, "98%/88% --H/4D")
        XCTAssertNil(MeterValue.summary(windows: [RateWindow(usedPercent: 10, durationMinutes: nil, resetsAt: nil)]))
    }

    func testDetailedResetTimeIncludesLocalTimeAndRemainingMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 8 * 3_600)!
        XCTAssertEqual(DetailTimeFormatter.reset(now.addingTimeInterval(90_060), now: now, timeZone: zone),
                       "01-02 09:01 (1d 1h 1m left)")
        XCTAssertEqual(DetailTimeFormatter.reset(now.addingTimeInterval(1), now: now, timeZone: zone),
                       "01-01 08:00 (1m left)")
        XCTAssertEqual(DetailTimeFormatter.reset(now.addingTimeInterval(-60), now: now, timeZone: zone),
                       "01-01 07:59 (Time's up)")
        XCTAssertEqual(DetailTimeFormatter.reset(nil, now: now, timeZone: zone), "Unknown (--H)")
    }

    func testWindowOrderDoesNotDependOnAPIOrder() {
        let windows = [nil, 1_440, 10_080, 300, 120].map {
            RateWindow(usedPercent: 25, durationMinutes: $0, resetsAt: nil)
        }
        XCTAssertEqual(DetailRowBuilder.orderedWindows(windows).map(\.durationMinutes), [300, 10_080, 120, 1_440, nil])
    }

    @MainActor
    func testReorderingMovesProviderReadingsAndSurvivesDataRefresh() {
        let view = NotchMeterView(frame: NSRect(x: 0, y: 0, width: 364, height: 32))
        view.configure(hasNotch: true, notchWidth: 180, notchHeight: 32, expanded: false)
        view.setCodex(value: MeterValue(percent: 20, resetText: "2H"))
        view.setClaude(value: MeterValue(percent: 40, resetText: "3H"))
        view.setGLM(value: MeterValue(percent: 60, resetText: "4H"))
        view.setAgentOrder([.glm, .codex, .claude])
        view.layoutSubtreeIfNeeded()
        func row(_ provider: MeterAgent) -> CompactMeterRowView {
            view.subviews.compactMap { $0 as? CompactMeterRowView }.first { $0.provider == provider }!
        }
        XCTAssertGreaterThan(row(.glm).frame.midY, row(.codex).frame.midY)
        XCTAssertEqual(row(.glm).percentText, "60%")
        XCTAssertEqual(row(.glm).timeText, "4H")
        XCTAssertGreaterThan(row(.codex).frame.midY, row(.claude).frame.midY)
        view.setGLM(value: MeterValue(percent: 50, resetText: "1H"))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(row(.glm).percentText, "50%")
        XCTAssertEqual(row(.glm).timeText, "1H")
    }

    func testRowPaddingAndDualProgressStayWithinPhysicalNotchHeight() {
        for height in [CGFloat(24), CGFloat(32), CGFloat(38)] {
            let wing = NSRect(x: 0, y: 0, width: 72, height: height)
            let rows = MeterLayout.rows(in: wing)
            XCTAssertEqual(wing.maxY - rows[0].maxY, MeterLayout.compactPadding, accuracy: 0.01)
            XCTAssertEqual(rows[2].minY - wing.minY, MeterLayout.compactPadding, accuracy: 0.01)
            XCTAssertEqual(rows[0].minX - wing.minX, MeterLayout.compactHorizontalPadding, accuracy: 0.01)
            XCTAssertEqual(wing.maxX - rows[0].maxX, MeterLayout.compactHorizontalPadding, accuracy: 0.01)
            for row in rows {
                let tracks = MeterLayout.progressTracks(in: row, paired: true)
                XCTAssertTrue(row.contains(tracks[0]))
                XCTAssertTrue(row.contains(tracks[1]))
                XCTAssertLessThan(tracks[0].maxX, tracks[1].minX)
                XCTAssertEqual(tracks[0].midY, tracks[1].midY)
            }
        }
    }
}
