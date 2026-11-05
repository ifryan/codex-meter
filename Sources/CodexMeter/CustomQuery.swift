// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

enum JSONField {
    static func value(_ root: Any, at path: String) -> Any? {
        if path.isEmpty || path == "$" { return root }
        let normalized = path.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "")
        let parts = normalized.split(separator: ".").map(String.init).filter { $0 != "$" }
        var current: Any = root
        for part in parts {
            if let object = current as? [String: Any], let next = object[part] { current = next }
            else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current is NSNull ? nil : current
    }

    static func decimal(_ value: Any?) -> Decimal? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            let decimal = number.decimalValue
            return decimal.isNaN ? nil : decimal
        }
        if let text = value as? String {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
            let number = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX"))
            return number.flatMap { $0.isNaN ? nil : $0 }
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let number = decimal(value) {
            var seconds = NSDecimalNumber(decimal: number).doubleValue
            if seconds > 100_000_000_000 { seconds /= 1_000 }
            guard seconds > 0, seconds < 253_402_300_800 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        return text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day.date(from: text) : nil
    }

    static func number(_ root: Any, _ path: String) -> Decimal? { decimal(value(root, at: path)) }
    static func text(_ root: Any, _ path: String) -> String? { value(root, at: path) as? String }

    static func structure(_ root: Any) -> [String] {
        var fields: [String] = []
        func walk(_ value: Any, path: String, depth: Int) {
            guard fields.count < 120, depth < 10 else { return }
            if let object = value as? [String: Any] {
                for key in object.keys.sorted().prefix(80) { walk(object[key]!, path: path.isEmpty ? key : path + "." + key, depth: depth + 1) }
            } else if let array = value as? [Any] {
                fields.append(path + " · array")
                if let first = array.first { walk(first, path: path + "[0]", depth: depth + 1) }
            } else {
                let type = value is NSNull ? "null" : value is String ? "string" : decimal(value) != nil ? "number" : "boolean"
                fields.append((path.isEmpty ? "$" : path) + " · " + type)
            }
        }
        walk(root, path: "", depth: 0)
        return fields
    }
}

enum MappingMode: String, Codable, CaseIterable, Sendable {
    case remaining, used, usedPercent, remainingPercent
    var title: String {
        switch self {
        case .remaining: return "返回值为剩余量"
        case .used: return "返回值为已用量"
        case .usedPercent: return "返回值为已用百分比"
        case .remainingPercent: return "返回值为剩余百分比"
        }
    }
}

struct MetricMapping: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var kind: MetricKind
    var valuePath: String
    var unit: String
    var totalPath: String = ""
    var resetPath: String = ""
    var rowsPath: String = ""
    var labelPath: String = ""
    var durationMinutes: Int? = nil
    var scale: Decimal = 1
    var mode: MappingMode = .remaining

    func extract(_ root: Any) -> [MonitorMetric] {
        let candidates: [Any]
        if rowsPath.isEmpty { candidates = [root] }
        else { candidates = JSONField.value(root, at: rowsPath) as? [Any] ?? [] }
        var occurrences: [String: Int] = [:]
        return candidates.prefix(200).enumerated().compactMap { index, item in
            guard let raw = JSONField.number(item, valuePath) else { return nil }
            let amount = raw * scale
            guard !amount.isNaN else { return nil }
            let total = totalPath.isEmpty ? nil : JSONField.number(item, totalPath).map { $0 * scale }
            let remaining: Decimal
            let capacity: Decimal?
            let used: Decimal?
            switch mode {
            case .remaining: remaining = amount; capacity = total; used = total.map { $0 - amount }
            case .used:
                if kind == .quota {
                    guard let total, total > 0 else { return nil }
                    remaining = max(0, total - amount); capacity = total; used = amount
                } else { remaining = amount; capacity = total; used = amount }
            case .usedPercent: remaining = max(0, 100 - amount); capacity = 100; used = amount
            case .remainingPercent: remaining = amount; capacity = 100; used = 100 - amount
            }
            let label = labelPath.isEmpty ? nil : JSONField.text(item, labelPath)
            let itemID = label.map { "\(id)." + Data($0.utf8).base64EncodedString() } ?? "\(id).\(index)"
            let occurrence = occurrences[itemID, default: 0]
            occurrences[itemID] = occurrence + 1
            return MonitorMetric(id: rowsPath.isEmpty ? id : itemID + ".\(occurrence)",
                                 title: label ?? title,
                                 kind: kind, value: remaining, unit: unit, total: capacity, used: used,
                                 resetsAt: resetPath.isEmpty ? nil : JSONField.date(JSONField.value(item, at: resetPath)),
                                 durationMinutes: durationMinutes)
        }
    }
}

struct CustomQuery: Codable, Equatable, Sendable {
    var url: String
    var method: String = "GET"
    var headers: [String: String] = ["Authorization": "Bearer ${token}"]
    var body: String = ""
    var mappings: [MetricMapping]
    var identityPath: String = ""
    var planPath: String = ""
    var allowsHTTP: Bool = false

    func validate() throws {
        guard let url = URL(string: url), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (allowsHTTP && url.scheme == "http") else {
            throw MonitorError.message("请输入 HTTPS 查询地址；本地 HTTP 服务需显式开启 HTTP")
        }
        guard ["GET", "POST"].contains(method), !mappings.isEmpty, mappings.count <= 50 else {
            throw MonitorError.message("查询需使用 GET / POST，并配置 1–50 个指标")
        }
        guard Set(mappings.map(\.id)).count == mappings.count else { throw MonitorError.message("指标 ID 不能重复") }
        for mapping in mappings {
            guard !mapping.scale.isNaN, mapping.scale > 0, !mapping.title.isEmpty,
                  mapping.durationMinutes == nil || (mapping.durationMinutes! > 0 && mapping.durationMinutes! <= 525_600) else {
                throw MonitorError.message("指标需有名称、正缩放系数及有效周期")
            }
        }
        for (name, value) in headers {
            guard !name.contains(where: { $0.isNewline || $0 == ":" }), !value.contains(where: \.isNewline) else {
                throw MonitorError.message("请求头不能包含换行")
            }
            let lower = name.lowercased()
            if ["authorization", "cookie", "key", "token", "secret", "password", "credential", "session", "signature"].contains(where: { lower.contains($0) }), !value.contains("${") {
                throw MonitorError.message("认证请求头请使用 ${token} 或 ${cookie}，凭据填写到安全凭据栏")
            }
        }
        if method == "GET" && !body.isEmpty { throw MonitorError.message("GET 查询不能附带请求体") }
        guard body.utf8.count <= 65_536 else { throw MonitorError.message("请求体过大") }
    }

    func request(secrets: [String: String]) throws -> URLRequest {
        try validate()
        guard let target = URL(string: url) else { throw MonitorError.invalidResponse }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        func expanded(_ text: String) throws -> String {
            var result = text
            for name in ["token", "cookie", "userID"] {
                let placeholder = "${\(name)}"
                if result.contains(placeholder) {
                    guard let value = secrets[name], !value.isEmpty, !value.contains(where: \.isNewline) else { throw MonitorError.notConfigured }
                    result = result.replacingOccurrences(of: placeholder, with: value)
                }
            }
            guard !result.contains("${") else { throw MonitorError.message("无法识别的凭据占位符") }
            return result
        }
        for (key, value) in headers { request.setValue(try expanded(value), forHTTPHeaderField: key) }
        if method == "POST" {
            // Credentials belong in headers, never interpolate them into exported request bodies.
            guard !body.contains("${") else { throw MonitorError.message("凭据占位符仅允许放在请求头中") }
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func parse(_ root: Any, account: SourceAccount) throws -> MonitorSnapshot {
        let metrics = mappings.flatMap { $0.extract(root) }
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics,
                               identity: identityPath.isEmpty ? nil : JSONField.text(root, identityPath),
                               plan: planPath.isEmpty ? nil : JSONField.text(root, planPath))
    }
}

final class MonitorHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = MonitorHTTP()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func data(_ request: URLRequest, maximumBytes: Int = 4 * 1_024 * 1_024) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 35
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw MonitorError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw MonitorError.http(response.statusCode) }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw MonitorError.message("查询响应超过大小限制") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw MonitorError.message("查询响应超过大小限制") }
                data.append(byte)
            }
            return data
        } catch let error as MonitorError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MonitorError.message("无法连接查询接口，请检查网络和连接配置") }
    }

    func json(_ request: URLRequest) async throws -> Any {
        let data = try await data(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw MonitorError.invalidResponse }
        return root
    }
}
