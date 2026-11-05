// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

enum CloudProviders {
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hmac(_ key: Data, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }
    private static func date(_ format: String, now: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format
        return formatter.string(from: now)
    }
    private static func credentials(_ secrets: [String: String]) throws -> (String, String) {
        guard let access = secrets["accessKey"], let secret = secrets["secretKey"], !access.isEmpty, !secret.isEmpty else { throw MonitorError.notConfigured }
        return (access, secret)
    }

    static func volcengine(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let (access, secret) = try credentials(secrets)
        let region = account.endpoint.isEmpty ? "cn-beijing" : account.endpoint
        guard region.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw MonitorError.message("请输入有效区域，如 cn-beijing") }
        let host = "open.volcengineapi.com"
        let contentType = "application/json; charset=utf-8"
        var lastError: Error = MonitorError.invalidResponse
        for action in ["GetAFPUsage", "GetCodingPlanUsage"] {
            do {
                let now = Date()
                let timestamp = date("yyyyMMdd'T'HHmmss'Z'", now: now)
                let day = date("yyyyMMdd", now: now)
                let query = "Action=\(action)&Region=\(region)&Version=2024-01-01"
                let body = Data()
                let payload = hash(body)
                let headers = "host:\(host)\nx-date:\(timestamp)\nx-content-sha256:\(payload)\ncontent-type:\(contentType)\n"
                let signed = "host;x-date;x-content-sha256;content-type"
                let canonical = "POST\n/\n\(query)\n\(headers)\n\(signed)\n\(payload)"
                let scope = "\(day)/\(region)/ark/request"
                let text = "HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(canonical.utf8)))"
                let key = hmac(hmac(hmac(hmac(Data(secret.utf8), day), region), "ark"), "request")
                let signature = hmac(key, text).map { String(format: "%02x", $0) }.joined()
                var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
                request.httpMethod = "POST"; request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(timestamp, forHTTPHeaderField: "X-Date")
                request.setValue(payload, forHTTPHeaderField: "X-Content-Sha256")
                request.setValue("HMAC-SHA256 Credential=\(access)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
                let root = try await MonitorHTTP.shared.json(request)
                if JSONField.value(root, at: "ResponseMetadata.Error") != nil { throw MonitorError.message("火山云查询被拒绝，请检查 AccessKey、区域与 Ark 只读权限") }
                let result = JSONField.value(root, at: "Result") ?? root
                var metrics: [MonitorMetric] = []
                for (key, title, minutes) in [("AFPFiveHour", "5 小时", Optional(300)), ("AFPWeekly", "每周", Optional(10_080)), ("AFPMonthly", "每月", nil)] {
                    if let item = JSONField.value(result, at: key), let metric = NativeMetrics.counted(item, id: key, title: title,
                        totalKeys: ["Quota"], usedKeys: ["Used"], resetKeys: ["ResetTime"], duration: minutes, unit: "AFP") { metrics.append(metric) }
                }
                let items = JSONField.value(result, at: "QuotaUsage") ?? JSONField.value(result, at: "Usages") ?? JSONField.value(result, at: "Details")
                for item in items as? [[String: Any]] ?? [] {
                    let name = JSONField.text(item, "Level") ?? JSONField.text(item, "Type") ?? JSONField.text(item, "Period") ?? ""
                    guard let used = JSONField.number(item, "Percent") ?? JSONField.number(item, "UsedPercent") ?? JSONField.number(item, "UsagePercent") else { continue }
                    let duration = ["session", "5h", "fivehour", "rolling_5h"].contains(name.lowercased()) ? 300 : ["weekly", "week", "7d"].contains(name.lowercased()) ? 10_080 : nil
                    metrics.append(NativeMetrics.percent(id: name, title: name, used: used,
                        reset: JSONField.date(item["ResetTime"] ?? item["ResetTimestamp"]), duration: duration))
                }
                if !metrics.isEmpty { return try ToolProviders.snapshot(account, metrics: metrics) }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    static func tencent(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let (access, secret) = try credentials(secrets)
        let region = account.endpoint.isEmpty ? "ap-guangzhou" : account.endpoint
        guard ["ap-guangzhou", "ap-singapore"].contains(region) else { throw MonitorError.message("腾讯企业套餐区域应为 ap-guangzhou 或 ap-singapore") }
        func call(_ action: String, body: [String: Any]) async throws -> Any {
            let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            let now = Date()
            let day = date("yyyy-MM-dd", now: now)
            let timestamp = String(Int(now.timeIntervalSince1970))
            let host = "tokenhub.tencentcloudapi.com"
            let contentType = "application/json; charset=utf-8"
            let signedHeaders = "content-type;host;x-tc-action"
            let canonical = "POST\n/\n\ncontent-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n\n\(signedHeaders)\n\(hash(payload))"
            let scope = "\(day)/tokenhub/tc3_request"
            let text = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(canonical.utf8)))"
            let key = hmac(hmac(hmac(Data(("TC3" + secret).utf8), day), "tokenhub"), "tc3_request")
            let signature = hmac(key, text).map { String(format: "%02x", $0) }.joined()
            var request = URLRequest(url: URL(string: "https://\(host)/")!)
            request.httpMethod = "POST"; request.httpBody = payload
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(action, forHTTPHeaderField: "X-TC-Action")
            request.setValue(timestamp, forHTTPHeaderField: "X-TC-Timestamp")
            request.setValue("2026-03-22", forHTTPHeaderField: "X-TC-Version")
            request.setValue(region, forHTTPHeaderField: "X-TC-Region")
            request.setValue("TC3-HMAC-SHA256 Credential=\(access)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
            let root = try await MonitorHTTP.shared.json(request)
            guard JSONField.value(root, at: "Response.Error") == nil else { throw MonitorError.message("腾讯云查询被拒绝，请检查 TokenHub 企业套餐与 CAM 权限") }
            return root
        }
        var metrics: [MonitorMetric] = []
        var offset = 0
        repeat {
            let root = try await call("DescribeTokenPlanList", body: ["Offset": offset, "Limit": 100])
            let plans = JSONField.value(root, at: "Response.TokenPlanSet") as? [[String: Any]] ?? []
            for plan in plans {
                guard let team = plan["TeamId"] as? String else { continue }
                let detail = try await call("DescribeTokenPlan", body: ["TeamId": team])
                let object = JSONField.value(detail, at: "Response") ?? plan
                if let package = JSONField.value(object, at: "PackageInfo"), var metric = NativeMetrics.counted(package, id: team,
                    title: JSONField.text(plan, "Name") ?? "企业套餐", totalKeys: ["CycleQuota", "TotalQuota"], usedKeys: ["TotalUsed"],
                    unit: JSONField.text(object, "ProductType") == "enterprise-auto" ? "tokens" : "credits") {
                    metric.resetsAt = JSONField.date(JSONField.value(object, at: "TokenSummary.CycleEndTime"))
                    metrics.append(metric)
                }
            }
            offset += plans.count
            let total = JSONField.number(root, "Response.TotalCount").map { NSDecimalNumber(decimal: $0).intValue } ?? offset
            if plans.count < 100 || offset >= total { break }
            guard offset < 1_000 else { throw MonitorError.message("企业套餐过多，请使用权限范围更小的访问密钥") }
        } while true
        return try ToolProviders.snapshot(account, metrics: metrics)
    }

    static func alibaba(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let global = account.sourceID == "alibaba-global"
        let host = global ? "modelstudio.console.alibabacloud.com" : "bailian.console.aliyun.com"
        let region = global ? "ap-southeast-1" : "cn-beijing"
        let code = global ? "sfm_codingplan_public_intl" : "sfm_codingplan_public_cn"
        let action = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
        let cookieMode = account.authentication == .cookie
        let gateway = cookieMode ? (global ? "bailian-singapore-cs.alibabacloud.com" : "bailian-cs.console.aliyun.com") : host
        var components = URLComponents(string: "https://\(gateway)/data/api.json")!
        if cookieMode {
            components.queryItems = [.init(name: "action", value: global ? "IntlBroadScopeAspnGateway" : "BroadScopeAspnGateway"),
                                     .init(name: "product", value: "sfm_bailian"), .init(name: "api", value: action), .init(name: "_v", value: "undefined")]
        } else {
            components.queryItems = [.init(name: "action", value: action), .init(name: "product", value: "broadscope-bailian"),
                                     .init(name: "api", value: "queryCodingPlanInstanceInfoV2"), .init(name: "currentRegionId", value: region)]
        }
        var request = try MonitorAdapter.request(components.string!, secrets: secrets, method: "POST",
            body: ["queryCodingPlanInstanceInfoRequest": ["commodityCode": code]])
        if account.authentication == .cookie {
            let cookie = secrets["cookie"] ?? ""
            var securityToken = cookie.split(separator: ";").compactMap { part -> String? in
                let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                return pieces.count == 2 && pieces[0] == "sec_token" ? String(pieces[1]).removingPercentEncoding : nil
            }.first
            if securityToken == nil {
                let page = try await MonitorHTTP.shared.data(MonitorAdapter.request("https://\(host)/", secrets: secrets))
                if let html = String(data: page, encoding: .utf8), let regex = try? NSRegularExpression(pattern: #"["']?sec_?[Tt]oken["']?\s*:\s*["']([^"']+)["']"#),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) { securityToken = String(html[range]) }
            }
            guard let securityToken, !securityToken.isEmpty else { throw MonitorError.message("百炼控制台会话缺少安全令牌，请重新连接网页账户") }
            let parameters: [String: Any] = ["Api": action, "V": "1.0", "Data": [
                "queryCodingPlanInstanceInfoRequest": ["commodityCode": code, "onlyLatestOne": true],
                "cornerstoneParam": ["feTraceId": UUID().uuidString.lowercased(), "feURL": "https://\(host)/", "protocol": "V2",
                                     "console": "ONE_CONSOLE", "productCode": "p_efm", "domain": host,
                                     "consoleSite": global ? "MODELSTUDIO_ALIBABACLOUD" : "BAILIAN_ALIYUN", "xsp_lang": "en-US"]]]
            let json = try JSONSerialization.data(withJSONObject: parameters)
            request.httpBody = form(["params": String(decoding: json, as: UTF8.self), "region": region, "sec_token": securityToken])
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            for name in ["login_aliyunid_csrf", "csrf"] {
                if let value = cookie.split(separator: ";").compactMap({ item -> String? in
                    let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    return pair.count == 2 && pair[0] == name ? String(pair[1]) : nil
                }).first {
                    request.setValue(value, forHTTPHeaderField: "x-xsrf-token")
                    request.setValue(value, forHTTPHeaderField: "x-csrf-token")
                    break
                }
            }
        } else if let token = secrets["token"] {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue(token, forHTTPHeaderField: "X-DashScope-API-Key")
        }
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(host)/\(region)/?tab=\(global ? "coding-plan" : "model")", forHTTPHeaderField: "Referer")
        let root = try await MonitorHTTP.shared.json(request)
        var metrics: [MonitorMetric] = []
        for object in objects(root) {
            for (prefix, title, minutes) in [("per5Hour", "5 小时", Optional(300)), ("perWeek", "每周", Optional(10_080)), ("perBillMonth", "每月", nil)] {
                if let metric = NativeMetrics.counted(object, id: "\(metrics.count).\(prefix)", title: title,
                    totalKeys: [prefix + "TotalQuota"], usedKeys: [prefix + "UsedQuota"], resetKeys: [prefix + "QuotaNextRefreshTime"], duration: minutes) { metrics.append(metric) }
            }
        }
        return try ToolProviders.snapshot(account, metrics: metrics)
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.keys.sorted().map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(values[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }

    static func objects(_ value: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 10 else { return [] }
        if let object = value as? [String: Any] { return [object] + object.keys.sorted().flatMap { objects(object[$0]!, depth: depth + 1) } }
        if let array = value as? [Any] { return array.prefix(500).flatMap { objects($0, depth: depth + 1) } }
        if let text = value as? String, text.utf8.count <= 1_048_576, let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) { return objects(decoded, depth: depth + 1) }
        return []
    }
}
