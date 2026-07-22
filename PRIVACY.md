# 隐私说明 / Privacy

Codex Meter 的设计目标是只在本机显示 Codex 用量。

## 应用处理的数据

应用只处理 `codex app-server` 返回的以下信息：

- 额度窗口和剩余百分比
- 重置时间
- 重置卡数量及到期时间
- 订阅计划标识

这些快照只保存在应用内存中，应用退出后不会保留。Codex Meter 不包含分析、广告、崩溃上报或自建网络服务。

## 身份验证

Codex Meter 不直接读取、接收或保存 Token、Cookie 和密码。它启动本机 Codex 可执行文件，由 Codex 自己读取当前登录态并完成必要的网络请求。因此 Codex 进程的网络行为和遥测设置仍受用户自己的 Codex 配置及 OpenAI 条款约束。

## 本地日志

应用会通过 macOS Unified Logging 记录刷新成功或失败。具体错误内容使用私有日志字段，不记录完整响应、Token 或账户标识。

## 可执行文件边界

应用会从标准位置和 `PATH` 查找 `codex`，也支持 `CODEX_METER_CODEX_PATH`。指定自定义路径意味着用户信任该可执行文件以当前账户权限运行。

---

Codex Meter processes rate-limit percentages, reset times, reset-credit metadata, and the plan identifier returned by the local Codex app-server. Snapshots remain in memory only. The app does not directly read or store tokens, cookies, or passwords, and it includes no analytics or custom backend. Authentication and network activity are performed by the locally installed Codex process.
