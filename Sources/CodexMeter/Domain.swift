// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct RateWindow: Equatable, Sendable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct RateBucket: Equatable, Sendable {
    let id: String
    let name: String?
    let primary: RateWindow?
    let secondary: RateWindow?
}

struct ResetCredit: Equatable, Sendable {
    let expiresAt: Date?
}

struct UsageSnapshot: Equatable, Sendable {
    let plan: String?
    let main: RateBucket
    let buckets: [RateBucket]
    let resetCreditCount: Int?
    let resetCredits: [ResetCredit]
    let fetchedAt: Date
}

/// Claude Code 的订阅额度，来自 `ClaudeUsageClient` 对私有 usage 接口的直接请求。
struct ClaudeUsageSnapshot: Equatable, Sendable {
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
    let capturedAt: Date

    /// 剩余最少的那个窗口，也就是真正卡住你的那个。收起态右翼显示它。
    var tightest: RateWindow? {
        [fiveHour, sevenDay]
            .compactMap { $0 }
            .min { $0.remainingPercent < $1.remainingPercent }
    }
}

/// Identifies which quota a `QuotaResetEvent` / notification is about.
enum MeterProvider: Sendable {
    case codex
    case claudeFiveHour
    case claudeSevenDay

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeFiveHour, .claudeSevenDay: return "Claude"
        }
    }

    var windowLabel: String {
        switch self {
        case .codex: return "主额度"
        case .claudeFiveHour: return "5 小时额度"
        case .claudeSevenDay: return "周额度"
        }
    }

    var threadIdentifier: String {
        switch self {
        case .codex: return "codex-quota"
        case .claudeFiveHour, .claudeSevenDay: return "claude-quota"
        }
    }

    var identifierPrefix: String {
        switch self {
        case .codex: return "codex-primary"
        case .claudeFiveHour: return "claude-5h"
        case .claudeSevenDay: return "claude-7d"
        }
    }
}

struct QuotaResetEvent: Equatable, Sendable {
    let previousRemainingPercent: Int
    let currentRemainingPercent: Int
    let detectedAt: Date
}

enum QuotaResetDetector {
    private static let nearFullRemainingPercent = 90
    private static let meaningfulIncrease = 5

    static func detect(previous: RateWindow?, current: RateWindow?, at detectedAt: Date) -> QuotaResetEvent? {
        guard
            let previousWindow = previous,
            let currentWindow = current
        else {
            return nil
        }

        let previousRemaining = previousWindow.remainingPercent
        let currentRemaining = currentWindow.remainingPercent
        let increase = currentRemaining - previousRemaining
        guard currentRemaining >= nearFullRemainingPercent, increase > 0 else { return nil }

        let reachedCompletelyFull = currentRemaining == 100
        let crossedNearFullThreshold = previousRemaining < nearFullRemainingPercent
        let resetWindowAdvanced: Bool
        if let previousReset = previousWindow.resetsAt, let currentReset = currentWindow.resetsAt {
            resetWindowAdvanced = currentReset > previousReset
        } else {
            resetWindowAdvanced = false
        }

        guard
            reachedCompletelyFull
                || crossedNearFullThreshold
                || resetWindowAdvanced
                || increase >= meaningfulIncrease
        else {
            return nil
        }

        return QuotaResetEvent(
            previousRemainingPercent: previousRemaining,
            currentRemainingPercent: currentRemaining,
            detectedAt: detectedAt
        )
    }
}

struct MeterDetailRow: Equatable, Sendable {
    let title: String
    let value: String
}

/// A single window's remaining percent + formatted reset countdown, pre-rendered for display —
/// e.g. the collapsed notch's "52% 3H". `nil` means the window doesn't exist for this account
/// (not that it failed to load), so callers should omit it rather than showing a placeholder.
struct MeterValue: Equatable, Sendable {
    let percent: Int
    let resetText: String

    var text: String { "\(percent)% \(resetText)" }
}

enum MeterError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case noResponse(String?)
    case server(String)
    case responseTooLarge
    case invalidResponse
    case claudeNotLoggedIn
    case claudeSessionExpired
    case claudeRequestFailed(String)
    case claudeResponseUnparseable

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex CLI。请安装 Codex，或通过 CODEX_METER_CODEX_PATH 指定路径。"
        case .launchFailed(let detail):
            return "无法启动 Codex：\(detail)"
        case .noResponse(let detail):
            guard let detail, !detail.isEmpty else { return "Codex 限额接口没有响应。" }
            return "Codex 限额接口没有响应：\(detail)"
        case .server(let detail):
            return "Codex 返回错误：\(detail)"
        case .responseTooLarge:
            return "Codex 返回的数据超过安全限制。"
        case .invalidResponse:
            return "无法解析 Codex 限额数据。"
        case .claudeNotLoggedIn:
            return "未找到 Claude Code 登录信息，请先运行 claude 并完成登录。"
        case .claudeSessionExpired:
            return "Claude 登录已过期，请打开 Claude Code 刷新登录状态。"
        case .claudeRequestFailed(let detail):
            return "Claude 额度接口请求失败：\(detail)"
        case .claudeResponseUnparseable:
            return "无法解析 Claude 额度数据。"
        }
    }
}

enum CompactTimeFormatter {
    static func text(until date: Date, now: Date = Date()) -> String {
        let remainingSeconds = max(0, date.timeIntervalSince(now))
        if remainingSeconds < 3_600 {
            return "\(Int(ceil(remainingSeconds / 60)))M"
        }
        if remainingSeconds <= 86_400 {
            return "\(Int(ceil(remainingSeconds / 3_600)))H"
        }
        return "\(Int(ceil(remainingSeconds / 86_400)))D"
    }
}

enum DurationLabelFormatter {
    static func label(_ minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) 周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }
}

enum DetailRowBuilder {
    static func codexResetCreditRow(for snapshot: UsageSnapshot, now: Date = Date()) -> MeterDetailRow {
        let reportedCount = max(0, snapshot.resetCreditCount ?? 0)
        let total = min(50, max(reportedCount, snapshot.resetCredits.count))
        guard total > 0 else {
            return MeterDetailRow(title: "暂无可用重置卡", value: "--")
        }

        let expirations = snapshot.resetCredits.compactMap(\.expiresAt).sorted()
        let expiryText = (0..<total).map { index in
            guard index < expirations.count else { return "--" }
            return CompactTimeFormatter.text(until: expirations[index], now: now)
        }.joined(separator: "/")
        return MeterDetailRow(title: "重置卡", value: expiryText)
    }

    static func windowRow(title: String, window: RateWindow?, now: Date = Date()) -> MeterDetailRow {
        guard let window else {
            return MeterDetailRow(title: title, value: "暂无额度窗口")
        }
        let reset = window.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) } ?? "未知"
        return MeterDetailRow(title: title, value: "剩余 \(window.remainingPercent)% · \(reset)")
    }
}

struct CodexUsageParser: Sendable {
    func parse(resultData: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let result: RateLimitsResultDTO
        do {
            result = try JSONDecoder().decode(RateLimitsResultDTO.self, from: resultData)
        } catch {
            throw MeterError.invalidResponse
        }

        let main = result.rateLimits.bucket(fallbackID: "codex")
        let buckets = (result.rateLimitsByLimitId ?? [:])
            .map { id, value in value.bucket(fallbackID: id) }
            .sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
        let credits = (result.rateLimitResetCredits?.credits ?? [])
            .map { ResetCredit(expiresAt: $0.expiresAt.map(Date.init(timeIntervalSince1970:))) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }

        return UsageSnapshot(
            plan: result.rateLimits.planType,
            main: main,
            buckets: buckets,
            resetCreditCount: result.rateLimitResetCredits?.availableCount,
            resetCredits: credits,
            fetchedAt: fetchedAt
        )
    }
}

private struct RateLimitsResultDTO: Decodable {
    let rateLimits: RateLimitSnapshotDTO
    let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
    let rateLimitResetCredits: ResetCreditsSummaryDTO?
}

private struct RateLimitSnapshotDTO: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?

    func bucket(fallbackID: String) -> RateBucket {
        RateBucket(
            id: limitId ?? fallbackID,
            name: limitName,
            primary: primary?.window,
            secondary: secondary?.window
        )
    }
}

private struct RateLimitWindowDTO: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var window: RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            durationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct ResetCreditsSummaryDTO: Decodable {
    let availableCount: Int
    let credits: [ResetCreditDTO]?
}

private struct ResetCreditDTO: Decodable {
    let expiresAt: TimeInterval?
}

/// 解析 `GET https://api.anthropic.com/api/oauth/usage` 的响应（即 `claude` CLI 的 `/usage`
/// 命令读取的同一个私有接口）。这是一个未公开文档化的内部接口，实际抓包确认的形状：
///
/// ```json
/// {"five_hour":{"utilization":24.0,"resets_at":"2026-09-02T06:50:00.427202+00:00",...},
///  "seven_day":{"utilization":3.0,"resets_at":"2026-09-03T07:00:00.427225+00:00",...}}
/// ```
///
/// `utilization` 是 0-100 的整数百分比，`resets_at` 是 ISO-8601 字符串（非 Unix 时间戳）。
/// 用 `JSONSerialization` 而非严格 `Decodable` 解析，接口细微调整时也不至于直接解析失败。
struct ClaudeUsageParser: Sendable {
    func parse(data: Data, capturedAt: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeterError.claudeResponseUnparseable
        }
        return ClaudeUsageSnapshot(
            fiveHour: Self.window(json["five_hour"]),
            sevenDay: Self.window(json["seven_day"]),
            capturedAt: capturedAt
        )
    }

    private static func window(_ raw: Any?) -> RateWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let rawPercent = (dict["utilization"] as? Double)
            ?? (dict["used_percentage"] as? Double)
            ?? (dict["percent"] as? Double)
        else { return nil }
        // Observed as a 0-100 value; tolerate a 0-1 fraction too in case that ever varies by field.
        let usedPercent = rawPercent <= 1 ? rawPercent * 100 : rawPercent
        let resetsAtString = (dict["resets_at"] as? String) ?? (dict["resetsAt"] as? String)
        return RateWindow(
            usedPercent: Int(usedPercent.rounded()),
            durationMinutes: nil,
            resetsAt: resetsAtString.flatMap(Self.parseISO8601)
        )
    }

    private static func parseISO8601(_ string: String) -> Date? {
        Self.iso8601WithFractionalSeconds.date(from: string) ?? Self.iso8601.date(from: string)
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
