// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

struct GLMQuota: Equatable, Sendable {
    let label: String
    let window: RateWindow
    let isMCP: Bool
}

struct GLMUsageSnapshot: Equatable, Sendable {
    let plan: String?
    let quotas: [GLMQuota]
    let capturedAt: Date

    var codingWindows: [RateWindow] { quotas.filter { !$0.isMCP }.map(\.window) }
    var tightest: RateWindow? { RateWindow.tightest(codingWindows) }
    var fiveHour: RateWindow? { RateWindow.tightest(codingWindows.filter { $0.durationMinutes == 300 }) }
    var sevenDay: RateWindow? { RateWindow.tightest(codingWindows.filter { $0.durationMinutes == 10_080 }) }
}

enum GLMError: LocalizedError, Equatable, Sendable {
    case notConfigured, invalidKey, keychainUnavailable, keychainWriteFailed, keychainAuthorizationRequired
    case unauthorized, rateLimited, timedOut, network, invalidResponse, noQuota, server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置，请在菜单中配置 GLM Coding Plan。"
        case .invalidKey: return "请输入有效的 API Key，不能包含空格或换行。"
        case .keychainUnavailable: return "无法读取钥匙串，请解锁后进入 GLM 配置重新授权。"
        case .keychainAuthorizationRequired: return "请进入 GLM 配置，留空点击保存并连接，完成一次性钥匙串授权迁移。"
        case .keychainWriteFailed: return "钥匙串操作失败，请解锁后重试。"
        case .unauthorized: return "API Key 无效或无权限，请检查 GLM 配置。"
        case .rateLimited: return "查询过于频繁，请稍后刷新。"
        case .timedOut: return "GLM 查询超时，请稍后刷新。"
        case .network: return "无法连接智谱，请检查网络后刷新。"
        case .invalidResponse: return "GLM 返回了无法识别的额度数据。"
        case .noQuota: return "未返回有效编程额度，请确认已开通 Coding Plan。"
        case .server(let status): return "GLM 查询失败（HTTP \(status)）。"
        }
    }
}

struct GLMUsageParser {
    func parse(data: Data, capturedAt: Date = Date()) throws -> GLMUsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["success"] as? Bool == true,
              let body = root["data"] as? [String: Any],
              let limits = body["limits"] as? [[String: Any]] else { throw GLMError.invalidResponse }
        let quotas: [GLMQuota] = limits.compactMap { item in
            guard let type = item["type"] as? String,
                  ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type),
                  let used = usedPercent(item) else { return nil }
            let unit = number(item["unit"])
            let count = number(item["number"])
            var minutes: Int?
            var period = "周期未知"
            // No duration inference from reset dates or array order. Months are calendar periods.
            if let count, count > 0, count <= 10_000, count.rounded() == count {
                switch unit {
                case 3: minutes = Int(count) * 60
                case 4: minutes = Int(count) * 1_440
                case 5: period = "\(Int(count)) 月"
                case 6: minutes = Int(count) * 10_080
                default: break
                }
            } else if count == nil, unit == 6 {
                minutes = 10_080
            } else if count == nil, unit == 5 {
                period = "月度"
            }
            if let minutes { period = DurationLabelFormatter.label(minutes) }
            let kind = type == "CREDIT_LIMIT" ? "积分" : (type == "TIME_LIMIT" ? "MCP" : "额度")
            let reset = number(item["nextResetTime"]).flatMap { value -> Date? in
                let seconds = value > 100_000_000_000 ? value / 1_000 : value
                guard seconds > 0, seconds < 253_402_300_800 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            return GLMQuota(
                label: "\(kind) \(period)",
                window: RateWindow(usedPercent: Int(min(100, max(0, used)).rounded()), durationMinutes: minutes, resetsAt: reset),
                isMCP: type == "TIME_LIMIT"
            )
        }
        guard quotas.contains(where: { !$0.isMCP }) else { throw GLMError.noQuota }
        return GLMUsageSnapshot(plan: body["level"] as? String, quotas: quotas, capturedAt: capturedAt)
    }

    private func usedPercent(_ item: [String: Any]) -> Double? {
        if let percentage = number(item["percentage"]) { return percentage }
        guard let total = number(item["usage"]), total > 0 else { return nil }
        if let used = number(item["currentValue"]), used >= 0 { return min(1, used / total) * 100 }
        if let remaining = number(item["remaining"]), remaining >= 0 { return (1 - min(1, remaining / total)) * 100 }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            result = value.doubleValue
        } else if let value = value as? String {
            result = Double(value)
        } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Prevent a server redirect from forwarding credentials away from the fixed monitor endpoint.
private final class GLMRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GLMUsageClient: Sendable {
    static let endpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let readKey: @Sendable () throws -> String?
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        readKey: @escaping @Sendable () throws -> String?,
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.readKey = readKey
        self.transport = transport ?? { try await Self.request($0) }
    }

    func fetch() async throws -> GLMUsageSnapshot {
        guard let key = try readKey() else { throw GLMError.notConfigured }
        let token = try GLMCredentialsStore.validated(key)
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw GLMError.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw GLMError.unauthorized
            case 429: throw GLMError.rateLimited
            default: throw GLMError.server(response.statusCode)
            }
            guard data.count <= 1_024 * 1_024 else { throw GLMError.invalidResponse }
            return try GLMUsageParser().parse(data: data)
        } catch let error as GLMError { throw error
        } catch is CancellationError { throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? GLMError.timedOut : GLMError.network
        } catch { throw GLMError.network }
    }

    private static func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: GLMRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}
