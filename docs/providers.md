# 来源与能力矩阵

目录有 41 个来源或模板条目，包含地区变体、已有工具连接和已停用接口，**不等于 41 家已经验证可用的服务**。

CI 在每次推送时运行单元测试和 Universal 2 构建，测试使用合成样例。各来源尚未逐项用真实账户核验，原生界面也未完成验收。下表表示已编写的读取路径与认证前提；接入是否成功还取决于相应账户、权限和服务商接口版本。SiliconFlow 的退役接口单独标注，不能列为当前可用余额能力。

| ID | 来源 | 读取路径／指标 | 认证与限制 |
| --- | --- | --- | --- |
| codex | Codex / ChatGPT | 本机 app-server；独立 OAuth 的 wham usage；额度窗口、储备信息、重置卡详情 | 本机当前 CLI、独立 auth.json 或 OAuth Access Token；普通 OpenAI API Key 不能替代订阅身份 |
| claude | Claude | OAuth usage；明确启用后才使用推理响应头；5 小时／周额度 | 当前 Claude Code、独立 OAuth JSON 或 profile-scoped OAuth Token；免费接口失效不自动开启付费探测 |
| glm | 智谱个人 Coding Plan | 国内监控接口；编程和 MCP 窗口 | Coding Plan Key；可复用或迁移旧专属钥匙串条目 |
| glm-team | 智谱团队 Coding Plan | 监控接口 type=2；套餐窗口 | 团队 Key、组织 ID、项目 ID |
| zai | Z.ai | 国际监控接口；套餐窗口 | 国际 Coding Plan Key |
| kimi / kimi-global | Kimi Code 国内／国际 | coding/v1/usages；窗口额度 | Coding Key；与 Moonshot 按量 API 分开 |
| minimax / minimax-global | MiniMax 国内／国际 | token_plan/remains；套餐各池余量 | Coding / Token Plan Key；无限窗口不伪造有限百分比 |
| opencode-go | OpenCode Go | Go usage；滚动、周、月窗口 | Go Key；不将 Zen 按量版计为同一套餐 |
| command-code | Command Code | billing credits；余额和返回的滚动窗口 | 账户 Key；只显示响应实际存在的字段 |
| alibaba / alibaba-global | 阿里 Coding Plan 国内／国际 | 控制台 RPC；5 小时、周、账月额度 | 套餐 Key 或控制台 Cookie；部分账户需要有效网页会话与安全令牌 |
| volcengine | 火山方舟 | 签名 GetAFPUsage / GetCodingPlanUsage | 账号 AK/SK、Ark 读取权限、区域；不是推理 Key |
| tencent | 腾讯 Token Plan 企业版 | TC3 签名查询套餐列表与详情 | SecretId / SecretKey、CAM 权限、广州或新加坡区域；不支持个人套餐用量查询 |
| zenmux | ZenMux | Management API 订阅窗口 | Management API Key；此适配器不承诺普通推理 Key 可查询 |
| copilot | GitHub Copilot | copilot_internal/user；quota snapshots | 设备授权、当前本机 Copilot 或 OAuth Token；不是普通 PAT 的通用能力 |
| gemini | Gemini CLI | loadCodeAssist / retrieveUserQuota；模型额度 | CLI OAuth 或独立账户；过期时通过原工具续期 |
| antigravity | Antigravity | fetchAvailableModels；返回的模型额度 | 独立 Google OAuth／项目；与 Gemini CLI 保持独立，不复用其默认账户 |
| cursor | Cursor | usage-summary；套餐与按量费用 | Cursor 明文应用／CLI 登录态或网页 Cookie；加密应用 Token 不自行解密，改用网页登录 |
| windsurf | Windsurf | 本地 plan cache 或网页 protobuf PlanStatus | 本机缓存可能陈旧；网页模式需要 devin_* 四项会话包 |
| kiro | Kiro | 已登录 kiro-cli 的 /usage 输出 | CLI 输出格式需要匹配；调用可能由 CLI 创建空会话，应用不删除原工具会话 |
| factory | Factory / Droid | billing/limits；新计量模式下的窗口 | API Key、Bearer 或 Cookie；当前适配新 token-rate-limit 账单形状 |
| warp | Warp | GraphQL RequestLimitInfo；Credits | Warp API Key；无限套餐用文字表示 |
| deepseek | DeepSeek API | user/balance；分币种余额 | 普通 API Key；不由余额推算历史费用 |
| moonshot / moonshot-global | Moonshot API 国内／国际 | users/me/balance；余额 | 区域 API Key；没有 Coding Plan 窗口 |
| openrouter | OpenRouter | Key usage 与可用的账户 Credits | Key 限额、累计费用与账户余额分别显示，不相加 |
| siliconflow / siliconflow-global | SiliconFlow 国内／国际 | 旧 user/info 解析及退役错误处理 | 已知旧查询已退役，410 显示不可用；不声称当前可读取余额 |
| stepfun / stepfun-global | StepFun API 国内／国际 | accounts；API 余额 | API Key；此适配器不把余额当作 Step Plan 额度 |
| novita | Novita AI | openapi/v1/billing/balance/detail | API Key；金额单位从万分之一美元转换 |
| aihubmix | AiHubMix | user/self；账户余额 | System Access Token；不以无限额推理 Key 代替账户 Token |
| openai-api | OpenAI API 组织 | 组织 costs / usage；近 30 个 UTC 日费用与 Token、按日历史 | Organization Admin Key，按分页读取；与 ChatGPT 订阅分开 |
| claude-api | Anthropic API 组织 | cost_report / usage_report；近 30 个 UTC 日费用与 Token、按日历史 | Anthropic Admin Key；与 Claude 订阅分开 |
| magpie | Magpie | 本机／HTTPS quotas、usage；额度、余额文字与近 30 天汇总 | Magpie 正在运行；受网关 Key 权限限制；保留远端缓存与估算标识 |
| cc-switch | CC Switch 导出 | 只读 CSV／JSON 的 Token 与费用记录 | 用户指定导出文件；不读取其凭据数据库；只代表文件中的覆盖范围 |
| custom | 自定义 | GET／POST、JSON 字段映射 | 无任意脚本；认证引用钥匙串占位符 |
| new-api | New API / One API 模板 | user/self；quota 缩放 | 实例地址、账户 Access Token 与用户 ID；部署单位不同时需调整系数 |
| sub2api | Sub2API 模板 | user/profile；余额 | 实例地址与登录 JWT；其他格式可编辑映射 |

## 本地用量日志

需要在“用量统计 → 采集与价格设置”主动开启。默认根目录可编辑：

| 工具 | 格式与范围 |
| --- | --- |
| Codex | sessions JSONL；累计 token_count 转增量，缓存读取与新输入分开 |
| Claude | projects JSONL；assistant 消息 usage，按请求 ID 更新流式结果 |
| Gemini CLI | tmp 下 chats/session-*.json；明确的 Token 字段 |
| OpenCode | 本地 message JSON；新版 opencode.db 的 message 表（只读，增量） |
| Pi | sessions JSONL；assistant usage 与可用的日志估算费用 |
| Kimi / MiniMax | 所选目录中兼容 assistant usage/tokens 结构的 JSONL；其他版本格式不声称已适配 |

日志默认记为“未归属”。仅当目录确实属于某一个账户时，才在设置中指定归属；不会根据当前 agent 的模型配置反推历史供应商。原始会话文本不写入历史库。

本地日志、CC Switch 导出和服务商账单在统计窗口中选择不同数据集，避免把同一请求的不同观察结果直接相加。没有覆盖所有数据源的全局请求 ID 时，不声称完成跨工具精确去重。

## 服务商账单历史

OpenAI／Anthropic 管理级连接读取最近 30 个 UTC 日，费用与 Token 日分组独立保存；当天刷新按稳定 ID 更新，不重复累加，允许服务商修正金额。账单统计按 UTC 日筛选，记录数不是请求次数。模型字段确实返回时才按模型展示 Token；未按模型拆分的组织费用单独列出，不按 Token 占比猜测费用。

账单仅显示当前连接凭据修订对应的数据，避免更换 Key 后混入原组织；旧行仍按保留期存储。两个 Key 可能有相同组织权限，应用无法仅凭 Key 证明互不重叠，请不要重复添加相同组织范围并相加。其他余额／窗口快照按自身时间展示，不能从余额差值推导支出。

## 验证记录约定

每个来源应分别记录：代码实现、脱敏样例、自动检查、真实账户、原生界面验收。某项检查通过不代表其他检查也通过。目前的自动检查覆盖构建和 `Tests/MeterlineTests` 中的合成样例，不代表真实账户或界面已验收。

参考：[CodexBar](https://github.com/steipete/CodexBar/tree/main/docs)、[Magpie](https://github.com/yetone/magpie/tree/main/internal/provider)、[CC Switch](https://github.com/farion1231/cc-switch)、[Novita 官方余额协议](https://docs.novita.ai/api-reference/basic-get-user-balance)、[ZenMux 官方协议](https://zenmux.ai/docs/guide/quickstart)。
