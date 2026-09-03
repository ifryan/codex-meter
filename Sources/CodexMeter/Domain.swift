// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct RateWindow: Equatable, Sendable, Codable {
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
    /// The account's credit reserve, when the plan exposes one. Distinct from `resetCredits`,
    /// which are the one-shot reset cards.
    let credits: CreditBalance?

    /// The account-level bucket Codex reports under the bare `codex` id; everything else is a
    /// model-scoped sub-limit such as Spark.
    var isAccountLevel: Bool { id == "codex" }

    /// "GPT-5.3-Codex-Spark" is too wide for the panel; the model family is the part that
    /// identifies the row.
    var shortName: String {
        guard let name, !name.isEmpty else { return id }
        if let spark = name.range(of: "Spark", options: .caseInsensitive) {
            let prefix = name[name.startIndex..<spark.lowerBound]
            let version = prefix.split(whereSeparator: { !"0123456789.".contains($0) }).last
            return version.map { "Spark \($0)" } ?? "Spark"
        }
        return name
    }
}

struct CreditBalance: Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    /// Nothing to show for an account that simply has no credit reserve.
    var isPresent: Bool { hasCredits || unlimited }

    var displayText: String {
        if unlimited { return "无限" }
        guard let balance, !balance.isEmpty else { return "--" }
        return balance
    }
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

/// Claude Code 的订阅额度，来自 `ClaudeUsageClient` 读取的 unified 限额响应头。
struct ClaudeUsageSnapshot: Equatable, Sendable, Codable {
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
    case claudeNotConfigured
    case claudeRequestFailed(String)
    case claudeTokenRejected

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
        case .claudeNotConfigured:
            return "未配置 Claude 令牌。运行 claude setup-token 后存入钥匙串，详见 README。"
        case .claudeTokenRejected:
            return "Claude 令牌已失效，请重新运行 claude setup-token 并更新钥匙串。"
        case .claudeRequestFailed(let detail):
            return "Claude 额度查询失败：\(detail)"
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
    let credits: CreditBalanceDTO?

    func bucket(fallbackID: String) -> RateBucket {
        RateBucket(
            id: limitId ?? fallbackID,
            name: limitName,
            primary: primary?.window,
            secondary: secondary?.window,
            credits: credits?.balanceValue
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

private struct CreditBalanceDTO: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    /// Reported as a string ("0"), not a number.
    let balance: String?

    var balanceValue: CreditBalance {
        CreditBalance(hasCredits: hasCredits ?? false, unlimited: unlimited ?? false, balance: balance)
    }
}

private struct ResetCreditsSummaryDTO: Decodable {
    let availableCount: Int
    let credits: [ResetCreditDTO]?
}

private struct ResetCreditDTO: Decodable {
    let expiresAt: TimeInterval?
}
/// 解析 `POST /v1/messages` 响应里的 `anthropic-ratelimit-unified-*` 头。实测形状：
///
/// ```
/// anthropic-ratelimit-unified-5h-utilization: 0.04
/// anthropic-ratelimit-unified-5h-reset: 1788418800
/// anthropic-ratelimit-unified-7d-utilization: 0.13
/// anthropic-ratelimit-unified-7d-reset: 1788418800
/// ```
///
/// 注意 `utilization` 在这里是 0-1 的小数，和 `/api/oauth/usage` 的 0-100 整数不同。
/// `reset` 是 Unix 秒级时间戳。任一窗口缺失都返回 nil，交由调用方按失败处理。
struct ClaudeRateLimitHeaderParser: Sendable {
    func parse(headers: [AnyHashable: Any], capturedAt: Date = Date()) -> ClaudeUsageSnapshot? {
        // Header names are case-insensitive, and URLSession does not normalise them, so index once.
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized["\(key)".lowercased()] = "\(value)"
        }

        let fiveHour = Self.window(prefix: "5h", in: normalized, durationMinutes: 300)
        let sevenDay = Self.window(prefix: "7d", in: normalized, durationMinutes: 10_080)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: capturedAt)
    }

    private static func window(prefix: String, in headers: [String: String], durationMinutes: Int) -> RateWindow? {
        guard
            let rawUtilization = headers["anthropic-ratelimit-unified-\(prefix)-utilization"],
            let utilization = Double(rawUtilization)
        else {
            return nil
        }
        // Observed as a 0-1 fraction; tolerate a 0-100 value in case that ever changes.
        let usedPercent = utilization <= 1 ? utilization * 100 : utilization
        let resetsAt = headers["anthropic-ratelimit-unified-\(prefix)-reset"]
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return RateWindow(
            usedPercent: Int(usedPercent.rounded()),
            durationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }
}

/// 解析 `GET https://api.anthropic.com/api/oauth/usage` 的响应 —— 即 `claude` CLI `/usage` 命令
/// 读取的同一个私有接口。只有带 `user:profile` 权限的会话令牌能调用它，因此这条路径只在
/// 回退到 Claude Code 自身登录态时才用得上。实测形状：
///
/// ```json
/// {"five_hour":{"utilization":24.0,"resets_at":"2026-09-02T06:50:00.427202+00:00",...},
///  "seven_day":{"utilization":3.0,"resets_at":"2026-09-03T07:00:00.427225+00:00",...},
///  "limits":[{"kind":"session","percent":17,"resets_at":"..."},
///            {"kind":"weekly_all","percent":12,"resets_at":"..."}]}
/// ```
///
/// 这里的 `utilization` 是 0-100，与响应头通道的 0-1 小数不同。用 `JSONSerialization` 而非严格
/// `Decodable`，接口细微调整时也不至于直接解析失败。
struct ClaudeUsageParser: Sendable {
    func parse(data: Data, capturedAt: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeterError.claudeRequestFailed("响应不是合法 JSON")
        }
        // 同样两个数字在响应里出现了两次：旧的 five_hour/seven_day 对象，和新的 limits 数组。
        // 优先用前者（目前仍然权威），后者作为回退，避免任一形状改名就直接空白。
        let limits = json["limits"] as? [[String: Any]] ?? []
        return ClaudeUsageSnapshot(
            fiveHour: Self.window(json["five_hour"], durationMinutes: 300)
                ?? Self.window(limits.first { $0["kind"] as? String == "session" }, durationMinutes: 300),
            sevenDay: Self.window(json["seven_day"], durationMinutes: 10_080)
                ?? Self.window(limits.first { $0["kind"] as? String == "weekly_all" }, durationMinutes: 10_080),
            capturedAt: capturedAt
        )
    }

    private static func window(_ raw: Any?, durationMinutes: Int) -> RateWindow? {
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
            durationMinutes: durationMinutes,
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
