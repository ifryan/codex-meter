// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

enum MetricKind: String, Codable, CaseIterable, Sendable {
    case quota, balance, tokens, cost
    var title: String {
        switch self { case .quota: return L("Quota"); case .balance: return L("Balance"); case .tokens: return "Token"; case .cost: return L("Cost") }
    }
}

enum MeasurementOrigin: String, Codable, Sendable {
    case provider, localLog, integration, estimate
    var title: String {
        switch self {
        case .provider: return L("Reported by provider")
        case .localLog: return L("Local logs")
        case .integration: return L("Existing tools")
        case .estimate: return L("Estimated from prices")
        }
    }
}

struct MonitorMetric: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: MetricKind
    var value: Decimal
    var unit: String
    var total: Decimal? = nil
    var used: Decimal? = nil
    var resetsAt: Date? = nil
    var durationMinutes: Int? = nil
    var origin: MeasurementOrigin = .provider
    var periodStart: Date? = nil
    var periodEnd: Date? = nil
    var primaryEligible = true

    var remainingPercent: Int? {
        guard kind == .quota || kind == .balance, let total, total > 0 else { return nil }
        return NSDecimalNumber(decimal: min(100, max(0, value / total * 100))).intValue
    }

    var formatted: String { MonitorFormat.amount(value, unit: unit) }
    var compact: String {
        if kind == .quota, let percent = remainingPercent { return "\(percent)%" }
        return MonitorFormat.amount(value, unit: unit, compact: true)
    }

    static func window(id: String, title: String, window: RateWindow) -> MonitorMetric {
        MonitorMetric(id: id, title: title, kind: .quota, value: Decimal(window.remainingPercent), unit: "%",
                      total: 100, used: Decimal(window.usedPercent), resetsAt: window.resetsAt, durationMinutes: window.durationMinutes)
    }
}

struct MonitorSnapshot: Codable, Equatable, Sendable {
    var accountID: UUID
    var sourceID: String
    var metrics: [MonitorMetric]
    var fetchedAt: Date = Date()
    var identity: String? = nil
    var plan: String? = nil
    var coverage: String? = nil
    var detailRows: [MonitorDetailRow] = []
    var credentialRevision: UUID? = nil
    var usageEvents: [UsageEvent] = []
}

struct MonitorDetailRow: Codable, Equatable, Sendable {
    var title: String
    var value: String
    var detail: String? = nil
}

enum AccountAuthentication: String, Codable, CaseIterable, Sendable {
    case local, token, cookie, oauthFile
    var title: String {
        switch self {
        case .local: return L("Reuse local sign-in")
        case .token: return "API Key / Access Token"
        case .cookie: return L("Web cookie")
        case .oauthFile: return L("Separate account file")
        }
    }
}

struct SourceAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var credentialRevision: UUID = UUID()
    var sourceID: String
    var name: String
    var enabled: Bool = true
    var pinned: Bool = false
    var authentication: AccountAuthentication = .token
    var credentialPath: String = ""
    var endpoint: String = ""
    var primaryMetricID: String? = nil
    var allowsPaidProbe: Bool = false
    var refreshMinutes: Int = 5
    var custom: CustomQuery? = nil
    var legacyCredentials: Bool = false

    func primary(in snapshot: MonitorSnapshot?) -> MonitorMetric? {
        guard let all = snapshot?.metrics else { return nil }
        if let primaryMetricID, let selected = all.first(where: { $0.id == primaryMetricID }) { return selected }
        let metrics = all.filter(\.primaryEligible)
        return metrics.filter({ $0.kind == .quota && $0.durationMinutes == 300 }).min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) })
            ?? metrics.filter({ $0.kind == .quota && $0.durationMinutes == 10_080 }).min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) })
            ?? metrics.first(where: { $0.kind == .quota })
            ?? metrics.first(where: { $0.kind == .balance }) ?? metrics.first
    }
}

struct MonitorConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var accounts: [SourceAccount]
    var prices: [ModelPrice] = []
    var historyDays: Int = 90
    var logsEnabled: Bool = false
    var logRoots: [String: String] = [:]
    var logAccountIDs: [String: UUID] = [:]

    mutating func normalize() {
        var seen = Set<UUID>()
        accounts = accounts.filter { seen.insert($0.id).inserted }
        var pinned = 0
        for index in accounts.indices {
            accounts[index].refreshMinutes = max(1, min(1_440, accounts[index].refreshMinutes))
            if accounts[index].pinned && accounts[index].enabled {
                pinned += 1
                if pinned > 3 { accounts[index].pinned = false }
            } else if !accounts[index].enabled { accounts[index].pinned = false }
        }
        historyDays = max(30, min(730, historyDays))
        upgradeStoredValues()
    }

    /// Rewrites values saved in Chinese by older versions. Safe to run on every load and save, which
    /// also covers templates imported from older exports.
    private mutating func upgradeStoredValues() {
        for index in accounts.indices {
            if let id = accounts[index].primaryMetricID {
                accounts[index].primaryMetricID = id.replacingPrefix("额度.", with: "quota.").replacingPrefix("额度 ", with: "quota-")
            }
            guard var custom = accounts[index].custom else { continue }
            for mapping in custom.mappings.indices where custom.mappings[mapping].unit == "次" {
                custom.mappings[mapping].unit = MonitorFormat.countUnit
            }
            accounts[index].custom = custom
        }
        for index in prices.indices {
            prices[index].version = prices[index].version.replacingPrefix("手工更新 / ", with: MonitorFormat.manualPriceVersionPrefix)
        }
    }
}

private extension String {
    func replacingPrefix(_ prefix: String, with replacement: String) -> String {
        hasPrefix(prefix) ? replacement + dropFirst(prefix.count) : self
    }
}

struct ModelPrice: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var model: String
    var inputPerMillion: Decimal
    var outputPerMillion: Decimal
    var cacheReadPerMillion: Decimal? = nil
    var cacheWritePerMillion: Decimal? = nil
    var currency: String = "USD"
    var version: String
}

enum MonitorFormat {
    /// Stored in snapshots and custom mappings. Don't wrap it in `L()`; `amount` translates it for display.
    static let countUnit = "uses"
    static let logPriceVersion = "log price estimate"
    static let manualPriceVersionPrefix = "manual / "

    static func amount(_ value: Decimal, unit: String, compact: Bool = false) -> String {
        let number = NSDecimalNumber(decimal: value)
        var suffix = ""
        var scaled = number
        if compact && unit != "%" {
            if abs(number.doubleValue) >= 1_000_000 { scaled = number.dividing(by: NSDecimalNumber(value: 1_000_000)); suffix = "M" }
            else if abs(number.doubleValue) >= 1_000 { scaled = number.dividing(by: NSDecimalNumber(value: 1_000)); suffix = "K" }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = (unit == "USD" || unit == "CNY") ? 4 : compact ? 1 : (unit == "tokens" || unit == countUnit ? 0 : 4)
        formatter.minimumFractionDigits = 0
        let text = formatter.string(from: scaled) ?? scaled.stringValue
        switch unit {
        case "USD": return "$\(text)\(suffix)"
        case "CNY": return "¥\(text)\(suffix)"
        case "%": return text + "%"
        case "tokens": return text + suffix + (compact ? "" : " Token")
        default: return text + suffix + (unit.isEmpty ? "" : " " + (unit == countUnit ? L("uses") : unit))
        }
    }
}

enum MonitorError: LocalizedError, Equatable {
    case message(String)
    case http(Int)
    case notConfigured
    case invalidResponse
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let code):
            switch code {
            case 401, 403: return L("The sign-in has expired or lacks permission. Reconnect the account")
            case 429: return L("Too many queries. Retrying later")
            default: return L("Query failed (HTTP %@)", "\(code)")
            }
        case .notConfigured: return L("Configure this account in Connections")
        case .invalidResponse: return L("The source returned no recognizable metrics. Check the plan and response format")
        case .keychain: return L("Couldn't access the Keychain. Unlock it, or save the credentials again in Connections")
        }
    }
}

struct PinnedReading: Equatable {
    var accountID: UUID
    var title: String
    var value: String
    var subtitle: String
    var percent: Int?
    var secondaryPercent: Int?
    var refreshing: Bool
}

struct MonitorSection: Equatable {
    var accountID: UUID
    var title: String
    var plan: String?
    var rows: [MonitorDetailRow]
}
