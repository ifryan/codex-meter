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
        .init(id: "codex", title: "Codex / ChatGPT", category: "订阅", capabilities: [.quota, .balance], authentication: [.local, .oauthFile, .token], dashboard: "https://chatgpt.com/codex/settings/usage", help: "本机模式只读取当前 Codex CLI 账户；独立账户可指定 auth.json，或填写 OAuth Access Token（不是 OpenAI API Key）", secretFields: ["token", "accountID"], localPaths: ["~/.codex/auth.json"]),
        .init(id: "claude", title: "Claude", category: "订阅", capabilities: [.quota], authentication: [.local, .oauthFile, .token], dashboard: "https://claude.ai/settings/usage", help: "优先使用 Claude Code 的 usage 接口；独立账户使用含 user:profile 权限的 OAuth Token。推理探测需单独开启", localPaths: ["~/.claude/.credentials.json"]),
        .init(id: "glm", title: "GLM Coding Plan · 国内", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://open.bigmodel.cn", help: "智谱国内 Coding Plan API Key；支持旧 GLM 配置迁移"),
        .init(id: "zai", title: "Z.ai Coding Plan · 国际", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://z.ai/manage-apikey", help: "Z.ai Coding Plan API Key"),
        .init(id: "glm-team", title: "GLM Coding Plan · 团队", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://open.bigmodel.cn", help: "团队 API Key、组织 ID 和项目 ID 缺一不可", secretFields: ["token", "organization", "project"]),
        .init(id: "kimi", title: "Kimi Code · 国内", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://www.kimi.com/code", help: "Kimi Code Key，不是 Moonshot API Key"),
        .init(id: "kimi-global", title: "Kimi Code · 国际", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://www.kimi.ai/code", help: "Kimi Code 国际 Key"),
        .init(id: "minimax", title: "MiniMax Coding Plan · 国内", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://platform.minimaxi.com", help: "Coding / Token Plan Key（sk-cp-…）"),
        .init(id: "minimax-global", title: "MiniMax Coding Plan · 国际", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://platform.minimax.io", help: "国际 Coding / Token Plan Key"),
        .init(id: "opencode-go", title: "OpenCode Go", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://opencode.ai/console", help: "Go Key；按量付费 Zen 不提供同一额度接口"),
        .init(id: "command-code", title: "Command Code", category: "Coding Plan", capabilities: [.quota, .balance], authentication: [.token], dashboard: "https://commandcode.ai", help: "Command Code 账户 Key"),
        .init(id: "alibaba", title: "阿里 Coding Plan · 国内", category: "Coding Plan", capabilities: [.quota], authentication: [.cookie, .token], dashboard: "https://bailian.console.aliyun.com", help: "部分国内账户必须使用百炼控制台登录 Cookie"),
        .init(id: "alibaba-global", title: "Alibaba Coding Plan · 国际", category: "Coding Plan", capabilities: [.quota], authentication: [.cookie, .token], dashboard: "https://modelstudio.console.alibabacloud.com", help: "Model Studio 控制台 Cookie 或套餐 Key"),
        .init(id: "volcengine", title: "火山方舟 Coding / Agent Plan", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://console.volcengine.com/ark", help: "需要账号 AccessKey ID / Secret，不是推理 Key。区域默认 cn-beijing", secretFields: ["accessKey", "secretKey"]),
        .init(id: "tencent", title: "腾讯云 Token Plan · 企业", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://console.cloud.tencent.com", help: "仅企业 Token Plan；需要腾讯云 SecretId / SecretKey", secretFields: ["accessKey", "secretKey"]),
        .init(id: "zenmux", title: "ZenMux", category: "Coding Plan", capabilities: [.quota], authentication: [.token], dashboard: "https://zenmux.ai", help: "需要 ZenMux Management API Key，查询订阅窗口"),
        .init(id: "copilot", title: "GitHub Copilot", category: "订阅", capabilities: [.quota], authentication: [.local, .token], dashboard: "https://github.com/settings/copilot", help: "使用 GitHub Device Flow 登录，或已有 Copilot OAuth Token；普通 PAT 不保证有 Copilot 权限", localPaths: ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"]),
        .init(id: "gemini", title: "Gemini CLI", category: "订阅", capabilities: [.quota], authentication: [.local, .oauthFile, .token], dashboard: "https://aistudio.google.com", help: "读取 Gemini CLI OAuth；过期时请通过原 CLI 续期。可填写项目 ID", secretFields: ["token", "projectID"], localPaths: ["~/.gemini/oauth_creds.json"]),
        .init(id: "antigravity", title: "Antigravity", category: "订阅", capabilities: [.quota], authentication: [.oauthFile, .token], dashboard: "https://antigravity.google", help: "独立 Google OAuth Access Token / 凭据文件；保持与 Gemini CLI 的账户及额度分离", secretFields: ["token", "projectID"]),
        .init(id: "cursor", title: "Cursor", category: "订阅", capabilities: [.quota, .cost], authentication: [.local, .cookie], dashboard: "https://cursor.com/settings", help: "读取当前 Cursor 应用 / CLI 登录态，或连接 cursor.com Cookie", localPaths: ["~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", "~/.config/cursor/auth.json"]),
        .init(id: "windsurf", title: "Windsurf", category: "订阅", capabilities: [.quota], authentication: [.local, .cookie], dashboard: "https://windsurf.com/profile", help: "本机模式读取应用缓存（可能陈旧）；网页模式使用含 devin_* 四项的 JSON 会话包", localPaths: ["~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"]),
        .init(id: "kiro", title: "Kiro", category: "订阅", capabilities: [.quota], authentication: [.local], dashboard: "https://kiro.dev", help: "使用已登录的 kiro-cli chat --no-interactive /usage；CLI 可能创建空会话", localPaths: ["~/.local/bin/kiro-cli", "/usr/local/bin/kiro-cli"]),
        .init(id: "factory", title: "Factory / Droid", category: "订阅", capabilities: [.quota], authentication: [.token, .cookie], dashboard: "https://app.factory.ai", help: "Factory API Key、Bearer Token 或网页会话"),
        .init(id: "warp", title: "Warp", category: "订阅", capabilities: [.quota], authentication: [.token], dashboard: "https://app.warp.dev", help: "Warp API Key"),
        .init(id: "deepseek", title: "DeepSeek API", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://platform.deepseek.com", help: "普通 API Key 可读账户余额；不据此推算历史消费"),
        .init(id: "moonshot", title: "Moonshot API · 国内", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://platform.moonshot.cn", help: "Moonshot 平台 Key；与 Kimi Code 套餐独立"),
        .init(id: "moonshot-global", title: "Moonshot API · 国际", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://platform.moonshot.ai", help: "国际 Moonshot Key，美元余额"),
        .init(id: "openrouter", title: "OpenRouter", category: "API 余额", capabilities: [.balance, .cost], authentication: [.token], dashboard: "https://openrouter.ai/settings/keys", help: "Key 额度与账户余额查询；不把两者相加"),
        .init(id: "siliconflow", title: "SiliconFlow · 国内", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://cloud.siliconflow.cn", help: "旧余额接口已被服务商停用；若返回 410，需使用有可用接口的自定义来源，不承诺可查询"),
        .init(id: "siliconflow-global", title: "SiliconFlow · 国际", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://cloud.siliconflow.com", help: "旧余额接口可能停用；停用状态不会显示为 0 余额"),
        .init(id: "stepfun", title: "StepFun API · 国内", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://platform.stepfun.com", help: "账户 API Key，人民币余额"),
        .init(id: "stepfun-global", title: "StepFun API · 国际", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://platform.stepfun.ai", help: "国际 API Key，美元余额"),
        .init(id: "novita", title: "Novita AI", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://novita.ai", help: "Novita API Key，账户余额"),
        .init(id: "aihubmix", title: "AiHubMix", category: "API 余额", capabilities: [.balance], authentication: [.token], dashboard: "https://aihubmix.com", help: "账户 System Access Token；不使用无限额推理 Key 伪造账户余额"),
        .init(id: "openai-api", title: "OpenAI API · 组织", category: "组织用量", capabilities: [.tokens, .cost], authentication: [.token], dashboard: "https://platform.openai.com/usage", help: "需要 Organization Admin Key，读取最近 30 天服务商用量与费用"),
        .init(id: "claude-api", title: "Anthropic API · 组织", category: "组织用量", capabilities: [.cost, .tokens], authentication: [.token], dashboard: "https://platform.claude.com", help: "需要 Anthropic Admin Key；与 Claude 订阅额度分开"),
        .init(id: "magpie", title: "Magpie", category: "已有工具", capabilities: [.quota, .balance, .tokens, .cost], authentication: [.token], dashboard: "http://127.0.0.1:3425", help: "连接正在运行的本机 Magpie HTTP API；只读取，不修改路由配置", defaultEndpoint: "http://127.0.0.1:3425"),
        .init(id: "cc-switch", title: "CC Switch 用量导出", category: "已有工具", capabilities: [.tokens, .cost], authentication: [.local], dashboard: "https://github.com/farion1231/cc-switch", help: "选择 CC Switch 用量导出的 CSV / JSON 文件，只读导入；不读取其密钥数据库"),
        .init(id: "custom", title: "自定义 HTTP / JSON", category: "自定义", capabilities: MetricKind.allCases, authentication: [.token, .cookie], dashboard: "", help: "配置查询表单和字段映射；凭据仅支持请求头占位符", secretFields: ["token", "cookie", "userID"]),
        .init(id: "new-api", title: "New API / One API", category: "自定义模板", capabilities: [.balance], authentication: [.token], dashboard: "", help: "填写实例地址，使用账户 Access Token 和用户 ID", secretFields: ["token", "userID"], customTemplate: CustomQuery(url: "", headers: ["Authorization": "Bearer ${token}", "New-Api-User": "${userID}"], mappings: [.init(title: "账户余额", kind: .balance, valuePath: "data.quota", unit: "USD", scale: Decimal(1) / 500_000)])),
        .init(id: "sub2api", title: "Sub2API", category: "自定义模板", capabilities: [.balance], authentication: [.token], dashboard: "", help: "填写实例地址，使用账户登录 JWT", customTemplate: CustomQuery(url: "", mappings: [.init(title: "账户余额", kind: .balance, valuePath: "data.balance", unit: "USD")]))
    ]

    static func descriptor(_ id: String) -> SourceDescriptor? { all.first { $0.id == id } }

    static func discovered() -> [SourceDescriptor] {
        all.filter { descriptor in
            descriptor.localPaths.contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
        }
    }
}
