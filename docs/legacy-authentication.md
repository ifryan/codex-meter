# 旧版认证说明（历史参考）

此文保存多来源改造前的认证说明，供旧凭据恢复参考。当前入口和行为以 README、隐私说明和迁移文档为准；原来默认发送的 Claude 推理探测现在必须显式开启。

## 工作方式

Codex 接入不实现自己的登录系统，也不要求用户粘贴 Codex Token。应用会启动本机可用的：

```text
codex app-server --stdio
```

然后通过本地 JSON-RPC 方法读取当前 Codex 登录态对应的限额数据。因此：

- Codex CLI、Codex App 或 ChatGPT App 必须已经登录；
- 如果账户由 auth.js 或其他工具同步到本机 Codex 登录态，只要 `codex app-server` 能识别，该账户就能正常显示；
- 应用本身不读取或保存 Codex 访问令牌；
- Codex 用量快照只保存在内存中，退出应用后不会保留；
- 实际网络访问和身份验证由本机 Codex 进程完成。

完整说明见 [PRIVACY.md](PRIVACY.md)。

## Claude 额度怎么来的

Claude Code 没有 Codex 那样的本地 JSON-RPC 接口，且没有任何本地文件记录额度百分比。Codex Meter 用两条通道读取，主路失败时自动回退。

### 主通道：unified 限额响应头（推荐，需一次性配置）

Anthropic 的每个**计费成功**的推理响应都会带上限额响应头：

```
anthropic-ratelimit-unified-5h-utilization: 0.04
anthropic-ratelimit-unified-5h-reset: 1788418800
anthropic-ratelimit-unified-7d-utilization: 0.13
anthropic-ratelimit-unified-7d-reset: 1788418800
```

这正是我们要显示的两个窗口。`claude setup-token` 签发的长期令牌（约 1 年有效）带 `user:inference` 权限，足以走这条路，因此**完全不依赖 Claude Code 是否在运行**。配置一次：

```sh
claude setup-token          # 按提示授权，复制 sk-ant-oat01-... 令牌
security add-generic-password -U \
  -s "Meterline Claude Token" -a "claude-usage-token" -w "<粘贴令牌>"
```

代价是每次刷新会发一个刻意最小化的请求（最便宜的模型、`max_tokens: 1`，约 10 tokens）。报错响应**不带**限额头（已对 403/404 实测确认），所以没有零成本读取的办法。

令牌优先级：环境变量 `METERLINE_CLAUDE_TOKEN` → 钥匙串条目 `Meterline Claude Token`（旧名 `CodexMeter Claude Token` 仍可读取）。

### 回退通道：`/api/oauth/usage` + Claude Code 登录态

主通道失败时，改用 `claude` CLI 自己在钥匙串里的登录态（服务名 `Claude Code-credentials`）请求 `GET https://api.anthropic.com/api/oauth/usage`，即 `/usage` 命令读的同一个接口。数据更全且不消耗额度，但这个会话令牌只有约 8 小时有效期，且**只在 Claude Code 实际运行时**才续期。

若该令牌已过期，Codex Meter 会在伪终端里启动 `claude` 并发送 `/status`，让 CLI **自己**完成刷新并写回钥匙串，然后重新读取 —— 全程只读，绝不自己写这个条目，从而避免与 CLI 的令牌轮换发生写冲突。该动作有 10 分钟冷却，且只在主通道已经失败后才触发。

注意 `claude setup-token` 的长期令牌**不能**用于这个接口，它要求 `user:profile` 权限：

```
403 permission_error
OAuth token does not meet scope requirement user:profile
```

### 取不到数据时的表现

- 每次成功拉取都会把快照缓存到 `~/Library/Application Support/CodexMeter/claude-usage.json`，两条通道都失败时继续显示上次的数值，并在明细面板标注“X 小时前”和具体原因，而不是直接空白（超过 7 天的缓存视为无效）；
- 未配置长期令牌、令牌失效等情况分别有独立提示。

### 已知限制

- 这些都是未公开文档化的私有接口与响应头，形状可能随版本变化；
- 如果你的网络需要代理才能访问 `api.anthropic.com`，请在系统网络设置里配置 —— GUI 应用不会继承 shell 的 `HTTPS_PROXY` 环境变量；
- Claude 凭证通过系统自带的 `/usr/bin/security` 读取，复用钥匙串条目对它的已有授权，避免 Codex Meter 的临时签名在重新构建后触发重复授权。按上面的 `security add-generic-password` 命令创建的长期令牌默认信任该工具；若条目由其他工具创建且未授权它，仍可能需要一次性授权。
- 长期令牌成功读取后仅缓存在进程内存中，每次刷新仍向服务端请求最新额度；401/403 响应会清除令牌缓存。已读取的有效令牌在钥匙串锁定后仍可用于请求，退出应用后不再保留。
- 正常登录且钥匙串已解锁时，已有授权的凭证读取不需要手动输入密码。钥匙串锁定时跳过新的凭证读取与 CLI 续期，系统解锁后在下一次刷新恢复；应用不会保存钥匙串密码或修改条目的访问权限。

完整说明见 [PRIVACY.md](PRIVACY.md)。

## GLM Coding Plan 配置

1. 点击刘海或顶部胶囊，选择 **配置 GLM Coding Plan…**。
2. 输入智谱国内版 Coding Plan API Key，点击 **保存并连接**。
3. 悬停查看连接结果、5 小时 / 每周额度、服务端返回的其他窗口，以及月度 MCP 额度。MCP 不参与常驻百分比的选择。

密钥通过 Security framework 保存至 macOS 钥匙串的 `Meterline GLM Coding Plan` 条目，账户名为 `glm-coding-plan-api-key`。不会写入普通配置、命令行参数或日志。配置窗口留空后点击保存，可使用并重新授权已保存的密钥；取消不改变配置；“移除配置”删除该条目并清除 GLM 快照。

查询使用 `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`，认证方式参考[智谱官方用量插件](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)。仅查询额度，不发送模型推理请求。兼容 `TOKENS_LIMIT` 和 `CREDIT_LIMIT`，未提供周期的窗口标注“周期未知”，无重置时间时常驻显示 `--H`。

后台读取钥匙串不弹出授权窗口；无法读取时，请解锁钥匙串并进入配置窗口重新授权。成功读取的密钥仅在当前进程内缓存。更换或移除密钥会丢弃旧请求结果，避免旧账户数据覆盖新配置。GLM 快照仅在内存中保留，查询失败会显示上次数据及错误原因，重启后重新查询。

当前支持一个智谱国内账户，不支持 Z.ai 国际版、多账户切换或 GLM 重置卡操作。接口不是稳定公开的 OpenAPI 契约，服务端响应变更可能需要更新解析器。真实账户响应仍需在配置后核对。

