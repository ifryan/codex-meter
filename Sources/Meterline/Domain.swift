// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct RateWindow: Equatable, Sendable, Codable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    /// The compact display consistently prefers the five-hour pool, then the weekly pool.
    /// Unsupported or unknown periods remain available in the detail panel only.
    static func displayWindow(_ windows: [RateWindow]) -> RateWindow? {
        tightest(windows.filter { $0.durationMinutes == 300 })
            ?? tightest(windows.filter { $0.durationMinutes == 10_080 })
    }

    static func tightest(_ windows: [RateWindow]) -> RateWindow? {
        windows.min {
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent < $1.remainingPercent }
            return ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        }
    }
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
        if unlimited { return L("Unlimited") }
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
    var identity: String? = nil
}

/// Claude Code 的订阅额度，来自 `ClaudeUsageClient` 读取的 unified 限额响应头。
struct ClaudeUsageSnapshot: Equatable, Sendable, Codable {
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
    let capturedAt: Date

    /// 剩余最少的窗口，用于额度分析；常驻展示使用 displayWindow 的周期优先规则。
    var tightest: RateWindow? {
        RateWindow.tightest([fiveHour, sevenDay].compactMap { $0 })
    }
}

/// Identifies which quota a `QuotaResetEvent` / notification is about.
enum MeterProvider: Sendable {
    case codex
    case claudeFiveHour
    case claudeSevenDay
    case glmFiveHour
    case glmSevenDay

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeFiveHour, .claudeSevenDay: return "Claude"
        case .glmFiveHour, .glmSevenDay: return "GLM"
        }
    }

    var windowLabel: String {
        switch self {
        case .codex: return L("Main quota")
        case .claudeFiveHour, .glmFiveHour: return L("5-hour quota")
        case .claudeSevenDay, .glmSevenDay: return L("Weekly quota")
        }
    }

    var threadIdentifier: String {
        switch self {
        case .codex: return "codex-quota"
        case .claudeFiveHour, .claudeSevenDay: return "claude-quota"
        case .glmFiveHour, .glmSevenDay: return "glm-quota"
        }
    }

    var identifierPrefix: String {
        switch self {
        case .codex: return "codex-primary"
        case .claudeFiveHour: return "claude-5h"
        case .claudeSevenDay: return "claude-7d"
        case .glmFiveHour: return "glm-5h"
        case .glmSevenDay: return "glm-7d"
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

enum MeterAgent: String, CaseIterable, Sendable {
    case codex, claude, glm

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .glm: return "GLM"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum MeterAgentOrder {
    static let defaultsKey = "meterAgentOrder"

    /// Keep recognized entries once, then append providers introduced by a newer app version.
    static func normalized(_ raw: [String]) -> [MeterAgent] {
        var result: [MeterAgent] = []
        for agent in raw.compactMap(MeterAgent.init(rawValue:)) + MeterAgent.allCases where !result.contains(agent) {
            result.append(agent)
        }
        return result
    }

    static func moving(_ agent: MeterAgent, to insertionIndex: Int, in order: [MeterAgent]) -> [MeterAgent] {
        var result = normalized(order.map(\.rawValue)).filter { $0 != agent }
        result.insert(agent, at: max(0, min(result.count, insertionIndex)))
        return result
    }
}

struct MeterDetailSection: Equatable, Sendable {
    let agent: MeterAgent
    let plan: String?
    let rows: [MeterDetailRow]
    var accountID: UUID? = nil
    var accountTitle: String? = nil
    var stableID: String { accountID?.uuidString ?? agent.rawValue }
    var title: String { accountTitle ?? agent.title }
}

struct MeterDetailRow: Equatable, Sendable {
    let title: String
    let value: String
    var detail: String? = nil
}

/// A single window's remaining percent + formatted reset countdown, pre-rendered for display —
/// e.g. the collapsed notch's "52% 3H". `nil` means the window doesn't exist for this account
/// (not that it failed to load), so callers should omit it rather than showing a placeholder.
struct MeterValue: Equatable, Sendable {
    let percent: Int
    let resetText: String
    var durationMinutes: Int? = nil
    var secondaryPercent: Int? = nil
    var secondaryResetText: String? = nil

    static func summary(windows: [RateWindow], now: Date = Date()) -> MeterValue? {
        guard let primary = RateWindow.displayWindow(windows) else { return nil }
        let weekly = primary.durationMinutes == 300
            ? RateWindow.tightest(windows.filter { $0.durationMinutes == 10_080 }) : nil
        return MeterValue(percent: primary.remainingPercent,
                          resetText: primary.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) } ?? "--H",
                          durationMinutes: primary.durationMinutes,
                          secondaryPercent: weekly?.remainingPercent,
                          secondaryResetText: weekly.map { window in
                              window.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) } ?? "--H"
                          })
    }

    static func tightest(_ values: [MeterValue?]) -> MeterValue? {
        values.compactMap { $0 }.min {
            if $0.percent != $1.percent { return $0.percent < $1.percent }
            return ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        }
    }

    var percentText: String { "\(percent)%" + (secondaryPercent.map { "/\($0)%" } ?? "") }
    var countdownText: String { resetText + (secondaryResetText.map { "/\($0)" } ?? "") }
    var text: String { "\(percentText) \(countdownText)" }
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
            return L("Codex CLI not found. Install Codex or set its path with METERLINE_CODEX_PATH.")
        case .launchFailed(let detail):
            return L("Couldn't start Codex: %@", "\(detail)")
        case .noResponse(let detail):
            guard let detail, !detail.isEmpty else { return L("The Codex rate-limit endpoint didn't respond.") }
            return L("The Codex rate-limit endpoint didn't respond: %@", "\(detail)")
        case .server(let detail):
            return L("Codex returned an error: %@", "\(detail)")
        case .responseTooLarge:
            return L("Codex returned more data than the safety limit allows.")
        case .invalidResponse:
            return L("Couldn't parse Codex rate-limit data.")
        case .claudeNotConfigured:
            return L("No Claude token configured. Run claude setup-token and store it in the Keychain. See the README.")
        case .claudeTokenRejected:
            return L("The Claude token has expired. Run claude setup-token again and update the Keychain.")
        case .claudeRequestFailed(let detail):
            return L("Claude quota query failed: %@", "\(detail)")
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
        guard let minutes else { return L("Quota") }
        if minutes % 10_080 == 0 { return L("%@W", "\(minutes / 10_080)") }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }
}

enum DetailRowBuilder {
    /// Five-hour and weekly windows lead; other known periods follow, unknown periods last.
    static func windowRank(_ window: RateWindow) -> Int {
        switch window.durationMinutes {
        case 300: return 0
        case 10_080: return 1
        default: return 2
        }
    }

    static func orderedWindows(_ windows: [RateWindow]) -> [RateWindow] {
        windows.enumerated().sorted {
            let lhs = windowRank($0.element), rhs = windowRank($1.element)
            if lhs != rhs { return lhs < rhs }
            let left = $0.element.durationMinutes ?? Int.max, right = $1.element.durationMinutes ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    static func windowTitle(_ minutes: Int?) -> String {
        switch minutes {
        case 300: return L("5-hour quota")
        case 10_080: return L("Weekly quota")
        case nil: return L("Quota with unknown period")
        default: return L("%@ quota", "\(DurationLabelFormatter.label(minutes))")
        }
    }

    static func codexResetCreditRow(for snapshot: UsageSnapshot, now: Date = Date()) -> MeterDetailRow {
        let reportedCount = max(0, snapshot.resetCreditCount ?? 0)
        let total = min(50, max(reportedCount, snapshot.resetCredits.count))
        guard total > 0 else {
            return MeterDetailRow(title: L("Reset cards"), value: L("None"))
        }

        let expirations = snapshot.resetCredits.compactMap(\.expiresAt).sorted()
        let expiryText = (0..<total).map { index in
            guard index < expirations.count else { return L("Card %@ has an unknown expiry", "\(index + 1)") }
            return L("Expires %@", "\(DetailTimeFormatter.reset(expirations[index], now: now))")
        }.joined(separator: "\n")
        return MeterDetailRow(title: L("Reset cards"), value: L("Cards: %@", "\(total)"), detail: expiryText)
    }

    static func windowRow(title: String, window: RateWindow?, now: Date = Date()) -> MeterDetailRow {
        guard let window else {
            return MeterDetailRow(title: title, value: L("No quota window yet"))
        }
        return MeterDetailRow(title: title, value: L("%@%% left", "\(window.remainingPercent)"),
                              detail: L("Resets %@", "\(DetailTimeFormatter.reset(window.resetsAt, now: now))"))
    }
}

enum DetailTimeFormatter {
    static func timestamp(_ date: Date, timeZone: TimeZone = .current, seconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = seconds ? "MM-dd HH:mm:ss" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func reset(_ date: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date else { return L("Unknown (--H)") }
        let minutes = Int(ceil(max(0, date.timeIntervalSince(now)) / 60))
        let remaining: String
        if minutes == 0 {
            remaining = L("Time's up")
        } else {
            var parts: [String] = []
            if minutes >= 1_440 { parts.append(L("%@d", "\(minutes / 1_440)")) }
            if minutes % 1_440 >= 60 { parts.append(L("%@h", "\(minutes % 1_440 / 60)")) }
            if minutes % 60 > 0 { parts.append(L("%@m", "\(minutes % 60)")) }
            remaining = L("%@ left", parts.joined(separator: L(" ")))
        }
        return L("%1$@ (%2$@)", timestamp(date, timeZone: timeZone), remaining)
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
            throw MeterError.claudeRequestFailed(L("The response isn't valid JSON"))
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
