// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ToolProviders {
    static func google(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let host = "https://cloudcode-pa.googleapis.com/v1internal:"
        if account.sourceID == "antigravity" {
            var body: [String: Any] = [:]
            if let project = secrets["projectID"], !project.isEmpty { body["project"] = project }
            let root = try await MonitorHTTP.shared.json(MonitorAdapter.request(host + "fetchAvailableModels", secrets: secrets, method: "POST", body: body))
            let models = JSONField.value(root, at: "models") as? [String: Any] ?? [:]
            let metrics = models.keys.sorted().compactMap { name -> MonitorMetric? in
                guard let model = models[name], let left = JSONField.number(model, "quotaInfo.remainingFraction") else { return nil }
                return NativeMetrics.percent(id: name, title: JSONField.text(model, "displayName") ?? name, used: 100 - left * 100,
                    reset: JSONField.date(JSONField.value(model, at: "quotaInfo.resetTime")))
            }
            return try snapshot(account, metrics: metrics)
        }
        var project = secrets["projectID"] ?? ""
        var plan: String?
        if project.isEmpty {
            let assist = try await MonitorHTTP.shared.json(MonitorAdapter.request(host + "loadCodeAssist", secrets: secrets, method: "POST",
                body: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]))
            project = JSONField.text(assist, "cloudaicompanionProject") ?? JSONField.text(assist, "cloudaicompanionProject.id") ?? ""
            plan = JSONField.text(assist, "currentTier.name")
        }
        let root = try await MonitorHTTP.shared.json(MonitorAdapter.request(host + "retrieveUserQuota", secrets: secrets, method: "POST",
            body: project.isEmpty ? [:] : ["project": project]))
        var byModel: [String: MonitorMetric] = [:]
        for (index, bucket) in (JSONField.value(root, at: "buckets") as? [[String: Any]] ?? []).enumerated() {
            guard let left = JSONField.number(bucket, "remainingFraction") else { continue }
            let name = JSONField.text(bucket, "modelId") ?? "额度 \(index + 1)"
            let metric = NativeMetrics.percent(id: name, title: name, used: 100 - left * 100, reset: JSONField.date(bucket["resetTime"]))
            if let previous = byModel[name], previous.value <= metric.value { continue }
            byModel[name] = metric
        }
        var result = try snapshot(account, metrics: byModel.keys.sorted().compactMap { byModel[$0] })
        result.plan = plan
        return result
    }

    static func cursor(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        var request = try MonitorAdapter.request("https://cursor.com/api/usage-summary", secrets: secrets)
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        let root = try await MonitorHTTP.shared.json(request)
        let plan = JSONField.value(root, at: "individualUsage.plan")
        var metrics: [MonitorMetric] = []
        let end = JSONField.date(JSONField.value(root, at: "billingCycleEnd"))
        if let plan {
            if let metric = NativeMetrics.counted(plan, id: "included", title: "套餐用量", totalKeys: ["limit"], usedKeys: ["used"], unit: "USD") {
                var converted = metric
                // Cursor's plan counters are US cents.
                converted.value /= 100; converted.total = converted.total.map { $0 / 100 }; converted.used = converted.used.map { $0 / 100 }
                converted.resetsAt = end
                metrics.append(converted)
            } else if let used = JSONField.number(plan, "totalPercentUsed") {
                metrics.append(NativeMetrics.percent(id: "included", title: "套餐用量", used: used, reset: end))
            }
        }
        if let amount = JSONField.number(root, "individualUsage.onDemand.used") {
            metrics.append(.init(id: "on-demand", title: "账期按量费用", kind: .cost, value: amount / 100, unit: "USD",
                                 periodStart: JSONField.date(JSONField.value(root, at: "billingCycleStart")), periodEnd: end))
        }
        var result = try snapshot(account, metrics: metrics)
        result.plan = JSONField.text(root, "membershipType")
        return result
    }

    static func windsurfLocal(_ account: SourceAccount) async throws -> MonitorSnapshot {
        try await Task.detached(priority: .utility) {
            let path = account.credentialPath.isEmpty ? "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb" : account.credentialPath
            guard let text = try ReadOnlySQLite.text(path: path, key: "windsurf.settings.cachedPlanInfo"), let data = text.data(using: .utf8) else { throw MonitorError.notConfigured }
            let root = try JSONSerialization.jsonObject(with: data)
            var metrics: [MonitorMetric] = []
            for (prefix, title, minutes) in [("daily", "每日", 1_440), ("weekly", "每周", 10_080)] {
                if let left = JSONField.number(root, "quotaUsage.\(prefix)RemainingPercent") {
                    metrics.append(NativeMetrics.percent(id: prefix, title: title, used: 100 - left,
                        reset: JSONField.date(JSONField.value(root, at: "quotaUsage.\(prefix)ResetAtUnix")), duration: minutes))
                }
            }
            for (key, used, total) in [("messages", "usedMessages", "messages"), ("flow", "usedFlowActions", "flowActions")] {
                if let usage = JSONField.value(root, at: "usage"), let metric = NativeMetrics.counted(usage, id: key, title: key,
                    totalKeys: [total], usedKeys: [used]) { metrics.append(metric) }
            }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            var result = try snapshot(account, metrics: metrics)
            result.fetchedAt = modified ?? .distantPast
            result.coverage = "Windsurf 本地缓存；仅在原应用更新时刷新，可能陈旧"
            return result
        }.value
    }

    static func windsurfWeb(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        guard let text = secrets["cookie"], let data = text.data(using: .utf8),
              let bundle = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let auth = bundle["devin_auth1_token"], let session = bundle["devin_session_token"],
              let id = bundle["devin_account_id"], let org = bundle["devin_primary_org_id"] else {
            throw MonitorError.message("请粘贴包含 devin_session_token、devin_auth1_token、devin_account_id、devin_primary_org_id 的 JSON 会话包")
        }
        var request = URLRequest(url: URL(string: "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus")!)
        request.httpMethod = "POST"
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/proto", forHTTPHeaderField: "Accept")
        request.setValue("https://windsurf.com", forHTTPHeaderField: "Origin")
        request.setValue(session, forHTTPHeaderField: "x-auth-token")
        request.setValue(session, forHTTPHeaderField: "x-devin-session-token")
        request.setValue(auth, forHTTPHeaderField: "x-devin-auth1-token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(id, forHTTPHeaderField: "x-devin-account-id")
        request.setValue(org, forHTTPHeaderField: "x-devin-primary-org-id")
        request.httpBody = ProtoFields.string(1, session) + ProtoFields.varintField(2, 1)
        let raw = try await MonitorHTTP.shared.data(request)
        let fields = try ProtoFields.decode(raw)
        // PlanStatus is carried in field 1; counters are documented by the service wire schema.
        let nested = try fields.bytes[1].flatMap { try ProtoFields.decode($0) } ?? fields
        var metrics: [MonitorMetric] = []
        for (key, resetKey, title, minutes) in [(14, 17, "每日", 1_440), (15, 18, "每周", 10_080)] {
            if let remaining = nested.numbers[key] {
                metrics.append(NativeMetrics.percent(id: String(key), title: title, used: 100 - Decimal(remaining),
                    reset: nested.numbers[resetKey].flatMap { JSONField.date(NSNumber(value: $0)) }, duration: minutes))
            }
        }
        return try snapshot(account, metrics: metrics)
    }

    static func kiro(_ account: SourceAccount) async throws -> MonitorSnapshot {
        let paths = account.credentialPath.isEmpty ? ["~/.local/bin/kiro-cli", "/opt/homebrew/bin/kiro-cli", "/usr/local/bin/kiro-cli"] : [account.credentialPath]
        guard let executable = paths.map({ NSString(string: $0).expandingTildeInPath }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MonitorError.message("未找到 kiro-cli，请在设置中指定可执行文件路径")
        }
        let output = try await MonitorCommand.output(executable: executable, arguments: ["chat", "--no-interactive", "/usage"])
        let text = output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var metrics: [MonitorMetric] = []
        let regex = try NSRegularExpression(pattern: #"(?im)^.*?(credits?|usage).*?(\d+(?:\.\d+)?)\s*(?:/|of)\s*(\d+(?:\.\d+)?).*$"#)
        for (index, match) in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated() {
            guard let left = Range(match.range(at: 2), in: text), let right = Range(match.range(at: 3), in: text),
                  let used = Decimal(string: String(text[left])), let total = Decimal(string: String(text[right])), total > 0 else { continue }
            metrics.append(.init(id: "credits.\(index)", title: "Credits", kind: .quota, value: max(0, total - used), unit: "credits", total: total, used: used))
        }
        return try snapshot(account, metrics: metrics)
    }

    static func factory(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        var request = try MonitorAdapter.request("https://api.factory.ai/api/billing/limits", secrets: secrets)
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        let root = try await MonitorHTTP.shared.json(request)
        var metrics: [MonitorMetric] = []
        for pool in ["standard", "core"] {
            for (key, title, minutes) in [("fiveHour", "5 小时", Optional(300)), ("weekly", "每周", Optional(10_080)), ("monthly", "每月", nil)] {
                guard let window = JSONField.value(root, at: "limits.\(pool).\(key)"), let used = JSONField.number(window, "usedPercent") else { continue }
                metrics.append(NativeMetrics.percent(id: "\(pool).\(key)", title: "\(pool) · \(title)", used: used,
                    reset: JSONField.date(JSONField.value(window, at: "windowEnd")), duration: minutes))
            }
        }
        return try snapshot(account, metrics: metrics)
    }

    static func warp(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let query = "query GetRequestLimitInfo($requestContext: RequestContext!) { user(requestContext: $requestContext) { ... on UserOutput { user { requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } } } } }"
        var request = try MonitorAdapter.request("https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo", secrets: secrets, method: "POST",
            body: ["query": query, "variables": ["requestContext": ["clientContext": [:] as [String: String],
                "osContext": ["category": "macOS", "name": "macOS", "version": ProcessInfo.processInfo.operatingSystemVersionString]]], "operationName": "GetRequestLimitInfo"])
        request.setValue("CodexMeter", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        let root = try await MonitorHTTP.shared.json(request)
        guard let info = JSONField.value(root, at: "data.user.user.requestLimitInfo") else { throw MonitorError.invalidResponse }
        if (info as? [String: Any])?["isUnlimited"] as? Bool == true {
            return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: [], detailRows: [.init(title: "Credits", value: "无限")])
        }
        guard let metric = NativeMetrics.counted(info, id: "credits", title: "Credits", totalKeys: ["requestLimit"], usedKeys: ["requestsUsedSinceLastRefresh"], resetKeys: ["nextRefreshTime"], unit: "credits") else { throw MonitorError.invalidResponse }
        return try snapshot(account, metrics: [metric])
    }

    static func commandMetrics(_ root: Any) -> [MonitorMetric] {
        let credits = JSONField.value(root, at: "credits") ?? root
        var metrics: [MonitorMetric] = []
        let names = ["monthlyCredits", "purchasedCredits", "freeCredits"]
        let values = names.compactMap { JSONField.number(credits, $0) }
        if !values.isEmpty { metrics.append(.init(id: "balance", title: "剩余 Credits", kind: .balance, value: values.reduce(0, +), unit: "USD")) }
        for (key, title, minutes) in [("fiveHour", "5 小时", 300), ("weekly", "每周", 10_080)] {
            if let window = JSONField.value(root, at: "windowLimits.\(key)") ?? JSONField.value(credits, at: "windowLimits.\(key)"),
               let metric = NativeMetrics.counted(window, id: key, title: title, totalKeys: ["cap", "limit", "limitUsd"], usedKeys: ["used", "usedUsd"], resetKeys: ["resetsAt", "resetAt"], duration: minutes, unit: "USD") { metrics.append(metric) }
        }
        return metrics
    }

    static func magpie(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let base = account.endpoint.isEmpty ? "http://127.0.0.1:3425" : account.endpoint
        guard let url = URL(string: base), let host = url.host, url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw MonitorError.message("Magpie 连接需使用本机地址或 HTTPS 服务")
        }
        var request = URLRequest(url: url.appendingPathComponent("v1/magpie/quotas"))
        if let token = secrets["token"], !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let root = try await MonitorHTTP.shared.json(request)
        let cards = (root as? [[String: Any]]) ?? (JSONField.value(root, at: "quotas") as? [[String: Any]]) ?? []
        var metrics: [MonitorMetric] = []
        var rows: [MonitorDetailRow] = []
        var readDates: [Date] = []
        for (index, card) in cards.enumerated() {
            let name = JSONField.text(card, "alias") ?? JSONField.text(card, "name") ?? JSONField.text(card, "provider") ?? "来源"
            let scope = (JSONField.text(card, "provider") ?? "source") + ":" + (JSONField.text(card, "user") ?? String(index))
            if let date = JSONField.date(card["readAt"] ?? card["asOf"]) { readDates.append(date) }
            if let issue = JSONField.text(card, "error"), !issue.isEmpty {
                rows.append(.init(title: name, value: "Magpie 此来源查询失败，所示数据可能陈旧"))
            }
            for (windowIndex, window) in (card["windows"] as? [[String: Any]] ?? []).enumerated() {
                if window["text"] as? Bool == true || window["unlimited"] as? Bool == true {
                    rows.append(.init(title: name, value: JSONField.text(window, "display") ?? "无限")); continue
                }
                if let used = JSONField.number(window, "used_percent") ?? JSONField.number(window, "used") {
                    var metric = NativeMetrics.percent(id: "\(scope).\(windowIndex)", title: name + " · " + (JSONField.text(window, "name") ?? "额度"), used: used,
                        reset: JSONField.date(window["resetsAt"] ?? window["resets_at"]))
                    metric.origin = .integration
                    metrics.append(metric)
                }
            }
            if let text = JSONField.text(card, "balance"), !text.isEmpty {
                let clean = text.replacingOccurrences(of: ",", with: "")
                if let first = clean.first, ["$", "¥", "￥"].contains(String(first)), let amount = JSONField.decimal(String(clean.dropFirst())) {
                    metrics.append(.init(id: scope + ".balance", title: name + " 余额", kind: .balance, value: amount,
                        unit: first == "$" ? "USD" : "CNY", origin: .integration))
                } else { rows.append(.init(title: name + " 余额", value: text)) }
            }
        }
        var usageRequest = URLRequest(url: url.appendingPathComponent("v1/magpie/usage").appending(queryItems: [.init(name: "period", value: "30d")]))
        usageRequest.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        do {
            let summary = try await MonitorHTTP.shared.json(usageRequest)
            let counts = ["input", "output", "cache_read", "cache_write"].compactMap { JSONField.number(summary, $0) }
            let start = JSONField.date(JSONField.value(summary, at: "since"))
            if !counts.isEmpty {
                metrics.append(.init(id: "usage.tokens", title: "Magpie 近 30 天 Token", kind: .tokens, value: counts.reduce(0, +), unit: "tokens", origin: .integration, periodStart: start, periodEnd: Date()))
            }
            if let cost = JSONField.number(summary, "cost") {
                metrics.append(.init(id: "usage.cost", title: "Magpie 已计价部分估算费用", kind: .cost, value: cost, unit: "USD", origin: .estimate, periodStart: start, periodEnd: Date()))
            }
            if let unpriced = JSONField.number(summary, "unpriced"), unpriced > 0 {
                rows.append(.init(title: "未计价请求", value: NSDecimalNumber(decimal: unpriced).stringValue))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { rows.append(.init(title: "Magpie 用量", value: "用量接口暂不可用，额度查询单独展示")) }
        guard !metrics.isEmpty || !rows.isEmpty else { throw MonitorError.invalidResponse }
        var result = MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics,
            fetchedAt: readDates.min() ?? Date(), coverage: "Magpie 已配置来源；费用按其计价口径估算。各来源数据可能有不同更新时间。", detailRows: rows)
        if cards.contains(where: { ($0["error"] as? String)?.isEmpty == false }) {
            result.coverage = "部分 Magpie 来源查询失败，所示为其缓存；不代表本机全部工具的完整用量"
        }
        return result
    }

    static func importedUsage(_ account: SourceAccount) async throws -> MonitorSnapshot {
        guard !account.credentialPath.isEmpty else { throw MonitorError.message("请选择 CC Switch 用量导出的 CSV / JSON 文件") }
        let events = try await UsageImport.read(account.credentialPath, accountID: account.id)
        let tokens = events.reduce(Int64(0)) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
        var metrics = [MonitorMetric(id: "tokens", title: "导出记录 Token", kind: .tokens, value: Decimal(tokens), unit: "tokens", origin: .integration)]
        let costs = Dictionary(grouping: events.filter { $0.cost != nil }, by: \.currency)
        for currency in costs.keys.sorted() {
            metrics.append(.init(id: "cost.\(currency)", title: "导出记录费用", kind: .cost,
                                 value: costs[currency]!.reduce(0) { $0 + ($1.cost ?? 0) }, unit: currency, origin: .integration))
        }
        var result = try snapshot(account, metrics: metrics)
        result.coverage = "仅所选导出文件记录；历史窗口依据每条记录的原始时间"
        return result
    }

    static func snapshot(_ account: SourceAccount, metrics: [MonitorMetric]) throws -> MonitorSnapshot {
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics)
    }
}

struct ProtoFields {
    var numbers: [Int: UInt64] = [:]
    var bytes: [Int: Data] = [:]
    static func varint(_ value: UInt64) -> Data {
        var number = value
        var result = Data()
        while number >= 128 { result.append(UInt8(number & 127) | 128); number >>= 7 }
        result.append(UInt8(number))
        return result
    }
    static func varintField(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func string(_ field: Int, _ text: String) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(text.utf8.count)) + Data(text.utf8) }
    static func decode(_ data: Data) throws -> ProtoFields {
        let bytes = Array(data)
        var offset = 0
        var result = ProtoFields()
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw MonitorError.invalidResponse }
                let byte = bytes[offset]; offset += 1
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw MonitorError.invalidResponse
        }
        while offset < bytes.count {
            let tag = try read()
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0: result.numbers[field] = try read()
            case 1: offset += 8
            case 2:
                let length = try read()
                guard length <= UInt64(bytes.count - offset) else { throw MonitorError.invalidResponse }
                result.bytes[field] = Data(bytes[offset..<offset + Int(length)]); offset += Int(length)
            case 5: offset += 4
            default: throw MonitorError.invalidResponse
            }
            guard offset <= bytes.count else { throw MonitorError.invalidResponse }
        }
        return result
    }
}
