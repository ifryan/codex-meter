// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SourceDescriptor: Identifiable, Sendable {
    var id: String
    var title: String
    var category: String
    var capabilities: [MetricKind]
    var authentication: [AccountAuthentication]
    var dashboard: String
    var help: String
    var secretFields: [String] = ["token"]
    var defaultEndpoint: String = ""
    var localPaths: [String] = []
    var customTemplate: CustomQuery? = nil
}

enum SourceRegistry {
    static let all: [SourceDescriptor] = [
        .init(id: "codex", title: "Codex / ChatGPT", category: L("Subscriptions"), capabilities: [.quota, .balance], authentication: [.local, .oauthFile, .token], dashboard: "https://chatgpt.com/codex/settings/usage", help: L("Local mode reads only the current Codex CLI account. Separate accounts can use their own auth.json or an OAuth access token (not an OpenAI API key)"), secretFields: ["token", "accountID"], localPaths: ["~/.codex/auth.json"]),
        .init(id: "claude", title: "Claude", category: L("Subscriptions"), capabilities: [.quota], authentication: [.local, .oauthFile, .token], dashboard: "https://claude.ai/settings/usage", help: L("Uses Claude Code's usage endpoint first. Separate accounts need an OAuth token with the user:profile scope. The inference probe must be turned on separately"), localPaths: ["~/.claude/.credentials.json"]),
        .init(id: "glm", title: L("GLM Coding Plan · China"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://open.bigmodel.cn", help: L("Zhipu China Coding Plan API key. Legacy GLM settings can be migrated")),
        .init(id: "zai", title: L("Z.ai Coding Plan · Global"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://z.ai/manage-apikey", help: "Z.ai Coding Plan API Key"),
        .init(id: "glm-team", title: L("GLM Coding Plan · Team"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://open.bigmodel.cn", help: L("Needs the team API key, organization ID, and project ID"), secretFields: ["token", "organization", "project"]),
        .init(id: "kimi", title: L("Kimi Code · China"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://www.kimi.com/code", help: L("Kimi Code key, not a Moonshot API key")),
        .init(id: "kimi-global", title: L("Kimi Code · Global"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://www.kimi.ai/code", help: L("Kimi Code global key")),
        .init(id: "minimax", title: L("MiniMax Coding Plan · China"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://platform.minimaxi.com", help: "Coding / Token Plan Key（sk-cp-…）"),
        .init(id: "minimax-global", title: L("MiniMax Coding Plan · Global"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://platform.minimax.io", help: L("Global Coding / Token Plan key")),
        .init(id: "opencode-go", title: "OpenCode Go", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://opencode.ai/console", help: L("Go key. Pay-as-you-go Zen has no equivalent quota endpoint")),
        .init(id: "command-code", title: "Command Code", category: "Coding Plan", capabilities: [.quota, .balance], authentication: [.token], dashboard: "https://commandcode.ai", help: L("Command Code account key")),
        .init(id: "alibaba", title: L("Alibaba Coding Plan · China"), category: "Coding Plan", capabilities: [.quota], authentication: [.cookie, .token], dashboard: "https://bailian.console.aliyun.com", help: L("Some China accounts must use a Bailian console sign-in cookie")),
        .init(id: "alibaba-global", title: L("Alibaba Coding Plan · Global"), category: "Coding Plan", capabilities: [.quota], authentication: [.cookie, .token], dashboard: "https://modelstudio.console.alibabacloud.com", help: L("Model Studio console cookie or plan key")),
        .init(id: "volcengine", title: L("Volcengine Ark Coding / Agent Plan"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://console.volcengine.com/ark", help: L("Needs an account AccessKey ID and secret, not an inference key. Region defaults to cn-beijing"), secretFields: ["accessKey", "secretKey"]),
        .init(id: "tencent", title: L("Tencent Cloud Token Plan · Enterprise"), category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://console.cloud.tencent.com", help: L("Enterprise Token Plan only. Needs a Tencent Cloud SecretId and SecretKey"), secretFields: ["accessKey", "secretKey"]),
        .init(id: "zenmux", title: "ZenMux", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://zenmux.ai", help: L("Needs a ZenMux Management API key to query subscription windows")),
        .init(id: "copilot", title: "GitHub Copilot", category: L("Subscriptions"), capabilities: [.quota], authentication: [.local, .token], dashboard: "https://github.com/settings/copilot", help: L("Sign in with GitHub Device Flow or use an existing Copilot OAuth token. A regular PAT may not have Copilot access"), localPaths: ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"]),
        .init(id: "gemini", title: "Gemini CLI", category: L("Subscriptions"), capabilities: [.quota], authentication: [.local, .oauthFile, .token], dashboard: "https://aistudio.google.com", help: L("Reads Gemini CLI OAuth. Renew it with the CLI when it expires. A project ID is optional"), secretFields: ["token", "projectID"], localPaths: ["~/.gemini/oauth_creds.json"]),
        .init(id: "antigravity", title: "Antigravity", category: L("Subscriptions"), capabilities: [.quota], authentication: [.oauthFile, .token], dashboard: "https://antigravity.google", help: L("Separate Google OAuth access token or credential file, kept apart from Gemini CLI accounts and quota"), secretFields: ["token", "projectID"]),
        .init(id: "cursor", title: "Cursor", category: L("Subscriptions"), capabilities: [.quota, .cost], authentication: [.local, .cookie], dashboard: "https://cursor.com/settings", help: L("Reads the current Cursor app or CLI sign-in, or connects a cursor.com cookie"), localPaths: ["~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", "~/.config/cursor/auth.json"]),
        .init(id: "windsurf", title: "Windsurf", category: L("Subscriptions"), capabilities: [.quota], authentication: [.local, .cookie], dashboard: "https://windsurf.com/profile", help: L("Local mode reads the app cache, which may be stale. Web mode uses a JSON session bundle with the four devin_* fields"), localPaths: ["~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"]),
        .init(id: "kiro", title: "Kiro", category: L("Subscriptions"), capabilities: [.quota], authentication: [.local], dashboard: "https://kiro.dev", help: L("Uses a signed-in kiro-cli chat --no-interactive /usage. The CLI may create an empty session"), localPaths: ["~/.local/bin/kiro-cli", "/usr/local/bin/kiro-cli"]),
        .init(id: "factory", title: "Factory / Droid", category: L("Subscriptions"), capabilities: [.quota], authentication: [.token, .cookie], dashboard: "https://app.factory.ai", help: L("Factory API key, bearer token, or web session")),
        .init(id: "warp", title: "Warp", category: L("Subscriptions"), capabilities: [.quota], authentication: [.token], dashboard: "https://app.warp.dev", help: "Warp API Key"),
        .init(id: "deepseek", title: "DeepSeek API", category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://platform.deepseek.com", help: L("A regular API key can read the account balance. Past spending isn't inferred from it")),
        .init(id: "moonshot", title: L("Moonshot API · China"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://platform.moonshot.cn", help: L("Moonshot platform key, separate from Kimi Code plans")),
        .init(id: "moonshot-global", title: L("Moonshot API · Global"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://platform.moonshot.ai", help: L("Global Moonshot key, balance in USD")),
        .init(id: "openrouter", title: "OpenRouter", category: L("API balances"), capabilities: [.balance, .cost], authentication: [.token], dashboard: "https://openrouter.ai/settings/keys", help: L("Queries the key limit and the account balance, and never adds them together")),
        .init(id: "siliconflow", title: L("SiliconFlow · China"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://cloud.siliconflow.cn", help: L("The provider has retired the old balance API. If it returns 410, use a custom source with a working endpoint. Queries aren't guaranteed")),
        .init(id: "siliconflow-global", title: L("SiliconFlow · Global"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://cloud.siliconflow.com", help: L("The old balance API may be retired. A retired API is never shown as a 0 balance")),
        .init(id: "stepfun", title: L("StepFun API · China"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://platform.stepfun.com", help: L("Account API key, balance in CNY")),
        .init(id: "stepfun-global", title: L("StepFun API · Global"), category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://platform.stepfun.ai", help: L("Global API key, balance in USD")),
        .init(id: "novita", title: "Novita AI", category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://novita.ai", help: L("Novita API key, account balance")),
        .init(id: "aihubmix", title: "AiHubMix", category: L("API balances"), capabilities: [.balance], authentication: [.token], dashboard: "https://aihubmix.com", help: L("Account System Access Token. An unlimited inference key is never passed off as an account balance")),
        .init(id: "openai-api", title: L("OpenAI API · Organization"), category: L("Organization usage"), capabilities: [.tokens, .cost], authentication: [.token], dashboard: "https://platform.openai.com/usage", help: L("Needs an Organization Admin key. Reads provider usage and cost for the last 30 days")),
        .init(id: "claude-api", title: L("Anthropic API · Organization"), category: L("Organization usage"), capabilities: [.cost, .tokens], authentication: [.token], dashboard: "https://platform.claude.com", help: L("Needs an Anthropic Admin key. Separate from Claude subscription quota")),
        .init(id: "magpie", title: "Magpie", category: L("Existing tools"), capabilities: [.quota, .balance, .tokens, .cost], authentication: [.token], dashboard: "http://127.0.0.1:3425", help: L("Connects to a running local Magpie HTTP API. Read-only, routing settings aren't changed"), defaultEndpoint: "http://127.0.0.1:3425"),
        .init(id: "cc-switch", title: L("CC Switch usage export"), category: L("Existing tools"), capabilities: [.tokens, .cost], authentication: [.local], dashboard: "https://github.com/farion1231/cc-switch", help: L("Choose a CC Switch usage export in CSV or JSON. Imported read-only, without reading its credential database")),
        .init(id: "custom", title: L("Custom HTTP / JSON"), category: L("Custom"), capabilities: MetricKind.allCases, authentication: [.token, .cookie], dashboard: "", help: L("Set up a query form and field mapping. Credentials only work as header placeholders"), secretFields: ["token", "cookie", "userID"]),
        .init(id: "new-api", title: "New API / One API", category: L("Custom templates"), capabilities: [.balance], authentication: [.token], dashboard: "", help: L("Enter the instance URL, and use an account access token and user ID"), secretFields: ["token", "userID"], customTemplate: CustomQuery(url: "", headers: ["Authorization": "Bearer ${token}", "New-Api-User": "${userID}"], mappings: [.init(title: L("Account balance"), kind: .balance, valuePath: "data.quota", unit: "USD", scale: Decimal(1) / 500_000)])),
        .init(id: "sub2api", title: "Sub2API", category: L("Custom templates"), capabilities: [.balance], authentication: [.token], dashboard: "", help: L("Enter the instance URL, and use an account sign-in JWT"), customTemplate: CustomQuery(url: "", mappings: [.init(title: L("Account balance"), kind: .balance, valuePath: "data.balance", unit: "USD")]))
    ]

    static func descriptor(_ id: String) -> SourceDescriptor? { all.first { $0.id == id } }

    static func discovered() -> [SourceDescriptor] {
        all.filter { descriptor in
            descriptor.localPaths.contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
        }
    }
}
