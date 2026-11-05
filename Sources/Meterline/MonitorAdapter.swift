// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MonitorAdapter: Sendable {
    private let legacyGLM = GLMCredentialsStore()

    func fetch(_ account: SourceAccount, secretsOverride: [String: String]? = nil) async throws -> MonitorSnapshot {
        try Task.checkCancellation()
        if account.sourceID == "codex", account.authentication == .local {
            let executable = account.credentialPath.isEmpty ? nil : URL(fileURLWithPath: NSString(string: account.credentialPath).expandingTildeInPath)
            return Self.codexSnapshot(try await CodexUsageClient(executableOverride: executable).fetch(), account: account)
        }
        if account.sourceID == "claude", account.authentication == .local {
            let snapshot = try await ClaudeUsageClient().fetch(allowsPaidProbe: account.allowsPaidProbe)
            let identity = await Task.detached(priority: .utility) {
                guard let root = try? LocalCredentials.jsonFile("~/.claude.json") else { return Optional<String>.none }
                return JSONField.text(root, "oauthAccount.emailAddress") ?? JSONField.text(root, "oauthAccount.accountUuid")
            }.value
            return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID,
                metrics: [snapshot.fiveHour.map { MonitorMetric.window(id: "five-hour", title: L("5 hours"), window: $0) },
                          snapshot.sevenDay.map { MonitorMetric.window(id: "weekly", title: L("Weekly"), window: $0) }].compactMap { $0 },
                fetchedAt: snapshot.capturedAt, identity: identity)
        }
        if account.sourceID == "kiro" { return try await ToolProviders.kiro(account) }
        if account.sourceID == "windsurf", account.authentication == .local { return try await ToolProviders.windsurfLocal(account) }
        if account.sourceID == "cc-switch" { return try await ToolProviders.importedUsage(account) }
        var secrets = try await Task.detached(priority: .utility) {
            if let secretsOverride { return secretsOverride }
            return try AccountSecrets.shared.read(account.id)
        }.value
        if account.legacyCredentials, account.sourceID == "glm", secrets["token"] == nil {
            secrets["token"] = try legacyGLM.read()
        }
        if account.authentication == .local || account.authentication == .oauthFile {
            secrets.removeValue(forKey: "token")
            secrets.removeValue(forKey: "cookie")
            secrets.removeValue(forKey: "accountID")
            secrets.merge(try await LocalCredentials.read(account)) { _, discovered in discovered }
        }
        if account.sourceID == "custom" || account.custom != nil {
            guard let custom = account.custom else { throw MonitorError.notConfigured }
            return try custom.parse(await MonitorHTTP.shared.json(custom.request(secrets: secrets)), account: account)
        }
        switch account.sourceID {
        case "codex": return try await Self.codexOAuth(account, secrets)
        case "claude": return try await Self.claudeOAuth(account, secrets)
        case "gemini", "antigravity": return try await ToolProviders.google(account, secrets)
        case "cursor": return try await ToolProviders.cursor(account, secrets)
        case "windsurf": return try await ToolProviders.windsurfWeb(account, secrets)
        case "factory": return try await ToolProviders.factory(account, secrets)
        case "warp": return try await ToolProviders.warp(account, secrets)
        case "alibaba", "alibaba-global": return try await CloudProviders.alibaba(account, secrets)
        case "volcengine": return try await CloudProviders.volcengine(account, secrets)
        case "tencent": return try await CloudProviders.tencent(account, secrets)
        case "magpie": return try await ToolProviders.magpie(account, secrets)
        case "openai-api", "claude-api": return try await Self.organization(account, secrets)
        default: return try await Self.keyed(account, secrets)
        }
    }

    static func request(_ url: String, secrets: [String: String], raw: Bool = false, method: String = "GET", body: Any? = nil) throws -> URLRequest {
        guard let target = URL(string: url), target.scheme == "https", target.user == nil, target.password == nil else {
            throw MonitorError.message(L("Built-in sources need a valid HTTPS URL"))
        }
        let token = secrets["token"] ?? ""
        guard !token.isEmpty || !(secrets["cookie"] ?? "").isEmpty else { throw MonitorError.notConfigured }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue(raw ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cookie = secrets["cookie"], !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func codexSnapshot(_ value: UsageSnapshot, account: SourceAccount) -> MonitorSnapshot {
        var metrics: [MonitorMetric] = []
        for bucket in [value.main] + value.buckets.filter({ $0.id != value.main.id }) {
            for (index, window) in [bucket.primary, bucket.secondary].enumerated() {
                guard let window else { continue }
                var metric = MonitorMetric.window(id: "\(bucket.id).\(index)", title: (bucket.isAccountLevel ? "" : bucket.shortName + " ") + DetailRowBuilder.windowTitle(window.durationMinutes), window: window)
                metric.primaryEligible = bucket.id == value.main.id
                metrics.append(metric)
            }
        }
        var rows: [MonitorDetailRow] = []
        if let credits = value.main.credits, credits.isPresent {
            rows.append(.init(title: L("Reserve credits"), value: credits.displayText))
        }
        let reset = DetailRowBuilder.codexResetCreditRow(for: value, now: Date())
        rows.append(.init(title: reset.title, value: reset.value, detail: reset.detail))
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics, fetchedAt: value.fetchedAt, identity: value.identity, plan: value.plan, detailRows: rows)
    }

    private static func codexOAuth(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        var request = try Self.request("https://chatgpt.com/backend-api/wham/usage", secrets: secrets)
        if let id = secrets["accountID"], !id.isEmpty { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let root = try await MonitorHTTP.shared.json(request)
        var metrics: [MonitorMetric] = []
        for key in ["primary_window", "secondary_window"] {
            if let window = JSONField.value(root, at: "rate_limit.\(key)") {
                guard let used = JSONField.number(window, "used_percent") else { continue }
                let duration = JSONField.number(window, "limit_window_seconds").map { NSDecimalNumber(decimal: $0 / 60).intValue }
                metrics.append(NativeMetrics.percent(id: key, title: DetailRowBuilder.windowTitle(duration), used: used,
                    reset: JSONField.date(JSONField.value(window, at: "reset_at")), duration: duration))
            }
        }
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics, plan: JSONField.text(root, "plan_type"))
    }

    private static func claudeOAuth(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        var request = try Self.request("https://api.anthropic.com/api/oauth/usage", secrets: secrets)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let data = try await MonitorHTTP.shared.data(request)
            let snapshot = try ClaudeUsageParser().parse(data: data)
            return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID,
                metrics: [snapshot.fiveHour.map { .window(id: "five-hour", title: L("5 hours"), window: $0) },
                          snapshot.sevenDay.map { .window(id: "weekly", title: L("Weekly"), window: $0) }].compactMap { $0 })
        } catch {
            guard account.allowsPaidProbe else { throw error }
            return try await paidClaudeProbe(account, secrets)
        }
    }

    private static func paidClaudeProbe(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        var request = try Self.request("https://api.anthropic.com/v1/messages", secrets: secrets, method: "POST", body: [
            "model": "claude-haiku-4-5-20251001", "max_tokens": 1, "messages": [["role": "user", "content": "."]]
        ])
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let session = URLSession(configuration: .ephemeral, delegate: MonitorHTTP.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let result = ClaudeRateLimitHeaderParser().parse(headers: http.allHeaderFields) else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID,
            metrics: [result.fiveHour.map { .window(id: "five-hour", title: L("5 hours"), window: $0) },
                      result.sevenDay.map { .window(id: "weekly", title: L("Weekly"), window: $0) }].compactMap { $0 },
            coverage: L("The inference-quota probe is turned on for this connection"))
    }

    private static func keyed(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let endpoints: [String: String] = [
            "glm": "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "zai": "https://api.z.ai/api/monitor/usage/quota/limit",
            "glm-team": "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2",
            "kimi": "https://api.kimi.com/coding/v1/usages", "kimi-global": "https://api.kimi.ai/coding/v1/usages",
            "minimax": "https://api.minimaxi.com/v1/token_plan/remains", "minimax-global": "https://api.minimax.io/v1/token_plan/remains",
            "opencode-go": "https://opencode.ai/zen/go/v1/usage", "command-code": "https://api.commandcode.ai/alpha/billing/credits",
            "deepseek": "https://api.deepseek.com/user/balance", "moonshot": "https://api.moonshot.cn/v1/users/me/balance",
            "moonshot-global": "https://api.moonshot.ai/v1/users/me/balance", "openrouter": "https://openrouter.ai/api/v1/key",
            "siliconflow": "https://api.siliconflow.cn/v1/user/info", "siliconflow-global": "https://api.siliconflow.com/v1/user/info",
            "stepfun": "https://api.stepfun.com/v1/accounts", "stepfun-global": "https://api.stepfun.ai/v1/accounts",
            "aihubmix": "https://aihubmix.com/api/user/self", "novita": "https://api.novita.ai/openapi/v1/billing/balance/detail",
            "copilot": "https://api.github.com/copilot_internal/user", "zenmux": "https://zenmux.ai/api/v1/management/subscription/detail"
        ]
        guard let endpoint = endpoints[account.sourceID] else { throw MonitorError.notConfigured }
        var query = try Self.request(endpoint, secrets: secrets, raw: ["glm", "glm-team", "zai"].contains(account.sourceID))
        if account.sourceID == "glm-team" {
            guard let organization = secrets["organization"], let project = secrets["project"], !organization.isEmpty, !project.isEmpty else { throw MonitorError.notConfigured }
            query.setValue(organization, forHTTPHeaderField: "bigmodel-organization")
            query.setValue(project, forHTTPHeaderField: "bigmodel-project")
        }
        if account.sourceID == "copilot" {
            query.setValue("token \(secrets["token"] ?? "")", forHTTPHeaderField: "Authorization")
            query.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
            query.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
            query.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
            query.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        }
        if account.sourceID == "opencode-go" { query.setValue(account.id.uuidString, forHTTPHeaderField: "x-opencode-session") }
        var root: Any
        do { root = try await MonitorHTTP.shared.json(query) }
        catch MonitorError.http(410) where account.sourceID.hasPrefix("siliconflow") {
            throw MonitorError.message(L("The provider has retired its balance API. Check its console instead. Older data doesn't reflect the current balance"))
        }
        if account.sourceID == "openrouter", var object = root as? [String: Any] {
            if let credits = try? await MonitorHTTP.shared.json(Self.request("https://openrouter.ai/api/v1/credits", secrets: secrets)) {
                object["accountCredits"] = JSONField.value(credits, at: "data")
                root = object
            }
        }
        let metrics = try NativeMetrics.parse(root, source: account.sourceID)
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics,
                               identity: JSONField.text(root, "login"), plan: JSONField.text(root, "copilot_plan") ?? JSONField.text(root, "data.level"))
    }

    private static func organization(_ account: SourceAccount, _ secrets: [String: String]) async throws -> MonitorSnapshot {
        let end = Date()
        var billingCalendar = Calendar(identifier: .gregorian)
        billingCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = billingCalendar.startOfDay(for: end.addingTimeInterval(-29 * 86_400))
        let openAI = account.sourceID == "openai-api"
        var metrics: [MonitorMetric] = []
        var events: [UsageEvent] = []
        for isCost in [true, false] {
            let base = openAI ? "https://api.openai.com/v1/organization/" : "https://api.anthropic.com/v1/organizations/"
            let path = openAI ? (isCost ? "costs" : "usage/completions") : (isCost ? "cost_report" : "usage_report/messages")
            var components = URLComponents(string: base + path)!
            if openAI {
                components.queryItems = [.init(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                                         .init(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                                         .init(name: "bucket_width", value: "1d"), .init(name: "limit", value: "31")]
            } else {
                let iso = ISO8601DateFormatter()
                components.queryItems = [.init(name: "starting_at", value: iso.string(from: start)),
                                         .init(name: "ending_at", value: iso.string(from: end)), .init(name: "bucket_width", value: "1d"),
                                         .init(name: "limit", value: "31")]
            }
            if !isCost { components.queryItems?.append(.init(name: "group_by[]", value: "model")) }
            var totals: [String: Decimal] = [:]
            var pages = 0
            repeat {
                var query = try Self.request(components.string!, secrets: secrets)
                if !openAI {
                    query.setValue(nil, forHTTPHeaderField: "Authorization")
                    query.setValue(secrets["token"], forHTTPHeaderField: "x-api-key")
                    query.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                }
                let root = try await MonitorHTTP.shared.json(query)
                guard let buckets = JSONField.value(root, at: "data") as? [[String: Any]] else { throw MonitorError.invalidResponse }
                for bucket in buckets {
                    guard let results = bucket["results"] as? [[String: Any]] else { throw MonitorError.invalidResponse }
                    for result in results {
                        guard let bucketTime = JSONField.date(bucket["start_time"] ?? bucket["starting_at"]) else { throw MonitorError.invalidResponse }
                        let model = isCost ? StoredLabel.organizationBill : JSONField.text(result, "model") ?? StoredLabel.organizationUsage
                        let context = ["project_id", "workspace_id", "api_key_id", "line_item"].map { JSONField.text(result, $0) ?? "" }.joined(separator: "|")
                        let eventID = "provider:\(account.id.uuidString):\(account.credentialRevision.uuidString):\(isCost ? "cost" : "tokens"):\(bucketTime.timeIntervalSince1970):\(model):\(context)"
                        if isCost {
                            let value = openAI ? JSONField.number(result, "amount.value") : JSONField.number(result, "amount").map { $0 / 100 }
                            guard let value else { throw MonitorError.invalidResponse }
                            let currency = JSONField.text(result, openAI ? "amount.currency" : "currency")?.uppercased() ?? "USD"
                            totals[currency, default: 0] += value
                            events.append(UsageEvent(id: eventID + ":" + currency, timestamp: bucketTime, tool: account.sourceID, accountID: account.id, model: model,
                                cost: value, currency: currency, origin: .provider, dataset: .provider))
                        } else {
                            var tokens: Decimal = 0
                            var foundCount = false
                            for key in openAI ? ["input_tokens", "output_tokens"] : ["uncached_input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation.ephemeral_5m_input_tokens", "cache_creation.ephemeral_1h_input_tokens"] {
                                if let count = JSONField.number(result, key) {
                                    guard count >= 0 else { throw MonitorError.invalidResponse }
                                    totals["tokens", default: 0] += count; tokens += count; foundCount = true
                                }
                            }
                            guard foundCount else { throw MonitorError.invalidResponse }
                            if tokens >= 0, tokens <= Decimal(Int64.max / 8) {
                                events.append(UsageEvent(id: eventID, timestamp: bucketTime, tool: account.sourceID, accountID: account.id, model: model,
                                    inputTokens: NSDecimalNumber(decimal: tokens).int64Value, origin: .provider, dataset: .provider))
                            }
                        }
                    }
                }
                pages += 1
                if (root as? [String: Any])?["has_more"] as? Bool == true {
                    guard let next = JSONField.text(root, "next_page"), !next.isEmpty else { throw MonitorError.invalidResponse }
                    components.queryItems?.removeAll { $0.name == "page" }
                    components.queryItems?.append(.init(name: "page", value: next))
                    guard pages < 100 else { throw MonitorError.message(L("Too many pages of organization billing. Narrow the query")) }
                } else { break }
            } while true
            if totals.isEmpty { totals[isCost ? "USD" : "tokens"] = 0 }
            for (unit, value) in totals.sorted(by: { $0.key < $1.key }) {
                metrics.append(MonitorMetric(id: isCost ? "cost.\(unit)" : "tokens", title: isCost ? L("Provider cost, last 30 days") : L("Tokens, last 30 days"),
                    kind: isCost ? .cost : .tokens, value: value, unit: unit, periodStart: start, periodEnd: end))
            }
        }
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics,
                               coverage: L("Organization totals for the last 30 UTC days, kept apart from local estimates. Costs not split by model aren't assigned to one. Different keys can belong to the same organization, so avoid adding the same billing scope twice."), usageEvents: events)
    }
}

enum NativeMetrics {
    static func percent(id: String, title: String, used: Decimal, reset: Date? = nil, duration: Int? = nil) -> MonitorMetric {
        MonitorMetric(id: id, title: title, kind: .quota, value: max(0, 100 - used), unit: "%", total: 100, used: used,
                      resetsAt: reset, durationMinutes: duration)
    }

    static func counted(_ object: Any, id: String, title: String, totalKeys: [String], usedKeys: [String], remainingKeys: [String] = [],
                        resetKeys: [String] = [], duration: Int? = nil, unit: String = MonitorFormat.countUnit) -> MonitorMetric? {
        let total = totalKeys.lazy.compactMap { JSONField.number(object, $0) }.first
        let used = usedKeys.lazy.compactMap { JSONField.number(object, $0) }.first
        let remaining = remainingKeys.lazy.compactMap { JSONField.number(object, $0) }.first ?? total.flatMap { total in used.map { total - $0 } }
        guard let remaining, let total, total > 0 else { return nil }
        return MonitorMetric(id: id, title: title, kind: .quota, value: max(0, remaining), unit: unit, total: total, used: used,
            resetsAt: resetKeys.lazy.compactMap { JSONField.date(JSONField.value(object, at: $0)) }.first, durationMinutes: duration)
    }

    static func parse(_ root: Any, source: String) throws -> [MonitorMetric] {
        var result: [MonitorMetric] = []
        func balance(_ path: String, unit: String, scale: Decimal = 1, title: String = L("Account balance")) {
            if let value = JSONField.number(root, path) {
                result.append(.init(id: path, title: title, kind: .balance, value: value * scale, unit: unit))
            }
        }
        switch source {
        case "glm", "glm-team", "zai":
            let data = try JSONSerialization.data(withJSONObject: root)
            let snapshot = try GLMUsageParser().parse(data: data)
            var occurrences: [String: Int] = [:]
            result = snapshot.quotas.map { quota in
                let base = "\(quota.isMCP ? "mcp" : "coding").\(quota.label).\(quota.window.durationMinutes.map(String.init) ?? "unknown")"
                let ordinal = occurrences[base, default: 0]
                occurrences[base] = ordinal + 1
                var metric = MonitorMetric.window(id: "\(base).\(ordinal)", title: quota.label, window: quota.window)
                metric.primaryEligible = !quota.isMCP
                return metric
            }
        case "deepseek":
            for (index, item) in (JSONField.value(root, at: "balance_infos") as? [[String: Any]] ?? []).enumerated() {
                if let value = JSONField.number(item, "total_balance"), let currency = item["currency"] as? String {
                    result.append(.init(id: "balance.\(currency).\(index)", title: L("Account balance"), kind: .balance, value: value, unit: currency))
                }
            }
        case "moonshot", "moonshot-global": balance("data.available_balance", unit: source == "moonshot" ? "CNY" : "USD")
        case "siliconflow", "siliconflow-global": balance("data.totalBalance", unit: source == "siliconflow" ? "CNY" : "USD")
        case "stepfun", "stepfun-global": balance("balance", unit: source == "stepfun" ? "CNY" : "USD")
        case "aihubmix": balance("data.quota", unit: "USD", scale: Decimal(1) / 500_000)
        case "novita": balance("availableBalance", unit: "USD", scale: Decimal(1) / 10_000)
        case "openrouter":
            if let remaining = JSONField.number(root, "data.limit_remaining") {
                result.append(.init(id: "key-budget", title: L("Current key's remaining quota"), kind: .balance, value: remaining, unit: "USD"))
            }
            if let used = JSONField.number(root, "data.usage") {
                result.append(.init(id: "key-usage", title: L("Current key's total cost"), kind: .cost, value: used, unit: "USD"))
            }
            if let credits = JSONField.number(root, "accountCredits.total_credits"), let usage = JSONField.number(root, "accountCredits.total_usage") {
                result.append(.init(id: "account-balance", title: L("Account balance (separate from the key limit)"), kind: .balance, value: credits - usage, unit: "USD"))
            }
        case "kimi", "kimi-global":
            if let weekly = JSONField.value(root, at: "usage"), let metric = counted(weekly, id: "weekly", title: L("Weekly"), totalKeys: ["limit"], usedKeys: ["used"], remainingKeys: ["remaining"], resetKeys: ["resetTime", "resetAt"], duration: 10_080) { result.append(metric) }
            for (index, item) in (JSONField.value(root, at: "limits") as? [[String: Any]] ?? []).enumerated() {
                let amount = JSONField.number(item, "window.duration").map { NSDecimalNumber(decimal: $0).intValue }
                let unit = JSONField.text(item, "window.timeUnit") ?? ""
                let minutes = amount.map { $0 * (unit.contains("HOUR") ? 60 : unit.contains("DAY") ? 1_440 : 1) }
                if let metric = counted(item["detail"] ?? item, id: "limit.\(index)", title: DetailRowBuilder.windowTitle(minutes), totalKeys: ["limit"], usedKeys: ["used"], remainingKeys: ["remaining"], resetKeys: ["resetTime", "resetAt"], duration: minutes) { result.append(metric) }
            }
        case "minimax", "minimax-global":
            guard JSONField.number(root, "base_resp.status_code") == 0 else { throw MonitorError.message(L("MiniMax returned no valid plan. Check your Coding Plan key")) }
            for item in (JSONField.value(root, at: "model_remains") as? [[String: Any]] ?? []) {
                let model = item["model_name"] as? String
                let name = model ?? "quota" // Part of the metric ID below, so it must not depend on the language.
                let displayName = model ?? L("Quota")
                for weekly in [false, true] {
                    let prefix = weekly ? "current_weekly" : "current_interval"
                    let status = JSONField.number(item, prefix + "_status")
                    if status == 3 { continue }
                    guard let left = status == 2 ? Decimal(0) : JSONField.number(item, prefix + "_remaining_percent") else { continue }
                    let start = JSONField.date(item[weekly ? "weekly_start_time" : "start_time"])
                    let end = JSONField.date(item[weekly ? "weekly_end_time" : "end_time"])
                    let duration = weekly ? 10_080 : start.flatMap { start in end.map { Int($0.timeIntervalSince(start) / 60) } }
                    var metric = percent(id: "\(name).\(prefix)", title: displayName + " · " + (weekly ? L("Weekly") : DetailRowBuilder.windowTitle(duration)), used: 100 - left, reset: end, duration: duration)
                    metric.primaryEligible = name.lowercased() == "general"
                    result.append(metric)
                }
            }
        case "opencode-go":
            for (key, title, minutes) in [("rolling", L("5 hours"), Optional(300)), ("weekly", L("Weekly"), Optional(10_080)), ("monthly", L("Monthly"), nil)] {
                if let used = JSONField.number(root, "usage.\(key).percent") {
                    result.append(percent(id: key, title: title, used: used,
                        reset: used > 0 ? JSONField.date(JSONField.value(root, at: "usage.\(key).resetsAt")) : nil, duration: minutes))
                }
            }
        case "copilot":
            let snapshots = JSONField.value(root, at: "quota_snapshots") as? [String: Any] ?? [:]
            for key in snapshots.keys.sorted() {
                let value = snapshots[key]!
                if let metric = counted(value, id: key, title: key, totalKeys: ["entitlement"], usedKeys: [], remainingKeys: ["remaining"], unit: MonitorFormat.countUnit) {
                    var metric = metric
                    metric.resetsAt = JSONField.date(JSONField.value(root, at: "quota_reset_date_utc") ?? JSONField.value(root, at: "quota_reset_date"))
                    result.append(metric)
                } else if let left = JSONField.number(value, "percent_remaining") {
                    result.append(percent(id: key, title: key, used: 100 - left))
                }
            }
        case "command-code": return ToolProviders.commandMetrics(root)
        case "zenmux":
            for (key, title, duration) in [("quota_5_hour", L("5 hours"), 300), ("quota_7_day", L("Weekly"), 10_080)] {
                if let item = JSONField.value(root, at: "data.\(key)") {
                    if let metric = counted(item, id: key, title: title, totalKeys: ["max_flows"], usedKeys: ["used_flows"], remainingKeys: ["remaining_flows"], resetKeys: ["resets_at"], duration: duration, unit: "flows") { result.append(metric) }
                    else if let used = JSONField.number(item, "usage_percentage") {
                        result.append(percent(id: key, title: title, used: used * 100, reset: JSONField.date(JSONField.value(item, at: "resets_at")), duration: duration))
                    }
                }
            }
        default: break
        }
        return result
    }
}
