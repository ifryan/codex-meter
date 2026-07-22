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

struct ResetCreditDisplayRow: Equatable, Sendable {
    let title: String
    let expiry: String
}

enum MeterError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case noResponse(String?)
    case server(String)
    case responseTooLarge
    case invalidResponse

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

enum ResetCreditRowBuilder {
    static func rows(for snapshot: UsageSnapshot, now: Date = Date()) -> [ResetCreditDisplayRow] {
        let reportedCount = max(0, snapshot.resetCreditCount ?? 0)
        let total = min(50, max(reportedCount, snapshot.resetCredits.count))
        guard total > 0 else {
            return [ResetCreditDisplayRow(title: "暂无可用重置卡", expiry: "--")]
        }

        let expirations = snapshot.resetCredits.compactMap(\.expiresAt).sorted()
        let expiryText = (0..<total).map { index in
            guard index < expirations.count else { return "--" }
            return CompactTimeFormatter.text(until: expirations[index], now: now)
        }.joined(separator: "/")
        return [ResetCreditDisplayRow(title: "重置卡", expiry: expiryText)]
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
