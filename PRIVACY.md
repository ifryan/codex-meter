# 隐私说明 / Privacy

Meterline 是本机用量监控工具，没有自建账户服务、分析、广告或自动上传历史记录的后台。

## 连接与启用

用户在连接设置中选择来源、认证和是否启用。新安装没有旧配置时从空列表开始。发现本机工具只检查已知路径是否存在，不代表已经读取其凭据或启用采集。旧版本迁移按原配置恢复已有三个连接。

已启用连接按自己的间隔刷新；后台最多同时执行四个读取任务。请求失败保留带时间标记的旧数据，不以零值代替失败。配置或凭据变化会取消旧请求、变更凭据修订号并隔离旧快照。

## 安全凭据

用户在安全凭据栏输入的 Key、OAuth Token、Cookie，以及云账号 AK/SK，按连接 UUID 存入 macOS 钥匙串的 `Meterline Connections` 条目。旧版的 `CodexMeter Connections` 条目会在首次读取时复制过来，并保留到连接被删除。不会导出到配置模板、写入普通配置或作为命令行参数传递。

成功读取的凭据只在进程内缓存。后台读取关闭钥匙串交互，不会弹出密码窗口；条目需要授权或钥匙串锁定时显示设置提示。用户保存或重新授权时，只为本应用专属条目信任当前应用，不开放所有应用，也不修改其他工具的条目。应用身份变化后（例如未经 Developer ID 签名的版本更新或重新构建），需要在连接编辑器中重新授权已有凭据，系统可能询问一次钥匙串密码。

原 GLM 专属条目兼容读取；显式迁移复制到新连接条目，不删除旧条目。原 Claude 本机登录态保持只读，必要时由其自己的 CLI 续期。应用不保存钥匙串密码。

普通配置字段、请求 URL、请求体和请求头常量属于可导出的模板内容，不能填入密钥。自定义认证使用安全凭据栏和 `${token}`、`${cookie}`、`${userID}` 请求头占位符。

## 本机登录态与网页登录

用户选择本机或独立文件认证后，应用只读对应 CLI／应用的认证文件或指定数据库。例如 Codex 当前账户仍由 app-server 完成认证；独立账户可读取用户指定的 OAuth 文件。Cursor 的不可解密登录态不会强行解密，用户可改用网页登录或 Cookie。

网页登录使用独立的临时 WebKit 数据存储。用户点击“完成连接”后，仅提取所选服务商域内的 Cookie；Windsurf 使用其明确的四项会话字段。不会把其他站点的登录态保存为该来源的凭据。Copilot 设备授权由用户在 GitHub 完成，取消编辑会取消本应用的等待任务。

这些登录页面及本机 CLI 可能依其自身规则联网、保存原工具登录态或产生会话记录；本应用不改写其默认账户，不删除其会话。Kiro 的 CLI 查询可能创建空会话。

## 网络访问

内置额度／余额适配器只请求该来源定义的接口。新通用 HTTP 客户端使用临时会话，拒绝重定向，限制超时和响应大小；不自动带系统 Cookie。自定义查询仅访问用户保存的地址，HTTP 需显式开启。

Claude 优先使用不发送推理请求的 usage 路径。只有用户开启相应连接的付费探测后，才会发送最小推理请求读取响应头；该开关默认关闭。

Magpie 只读其本机或 HTTPS quotas／usage 接口，不改写路由配置。CC Switch 只读用户选择的 CSV／JSON 用量导出，不读取其密钥数据库。

只有用户点击“从 models.dev 补充价格”时才访问 `https://models.dev/api.json`，不附带账户凭据或会话内容。导入目录中零值不自动认定为免费；已保存的自定义价格优先。

## 本地存储与历史

目录：`~/Library/Application Support/Meterline/`。

- `connections.json`：连接 UUID、用户命名、来源、认证模式、非敏感查询配置、路径、常驻项、日志账户绑定与价格。
- `usage.sqlite`：用量事件、额度快照和导入位置。快照可包含来源返回的账号标识、套餐、余额、额度及更新时间；事件包含时间、工具、账户 UUID、模型、Token、费用、币种、价格版本及数据口径。
- `claude-usage.json`：旧版 Claude 快照兼容文件；不包含凭证。
- 原有 UserDefaults：旧来源排序及 Codex 路径等兼容设置。

新配置和历史文件按当前用户可读写权限保存；SQLite 是本地普通数据库，不宣称加密数据库。默认保留 90 天历史，可设置 30–730 天。删除连接会删除其新专属凭据和当前快照，历史事件按保留期保留，显示为已移除账户。

“清除本地历史”保留连接、凭据和导入位置。“重新导入日志”重置导入进度，按稳定 ID 去重。原工具日志不删除。

## 日志采集和计价

本地日志采集默认关闭。启用后，应用在内存中解析所选目录中的日志／只读数据库，持久化时只提取用量字段，不保存提示词、回复、代码或完整会话文本。

本地日志与已有工具导出使用不同统计数据集。没有可靠跨工具 ID 时不自动汇总为一份完整账单。未知账户默认“未归属”，用户可为确属单一账户的目录指定绑定；不按当前工具配置反推历史上游。

组织账单使用独立数据集，按服务商 UTC 日保存，记录数不代表请求次数。当前视图只选择当前凭据修订的账单；更换 Key 后旧行按保留期保存。未按模型拆分的费用不分摊给模型。同组织的不同 Key 可能覆盖同一账单，应用不宣称能自动识别这种重叠。

费用区分服务商返回、已有工具结果及价格估算，不同币种不直接相加。未知模型价格或必要缓存价格缺失时保留未知，不视为免费。订阅的 API 价估算不是用户实付金额。

## 通知和诊断

用户允许后，由 macOS 发送本地额度重置通知；通知可能包含用户命名的连接、窗口和余量。首次读取、未知或已变化的本机身份不会用于推断重置。应用不会把这些通知发送到自建服务。

错误状态仅显示查询／认证／存储结果，不主动上传诊断。提交 Issue 前应脱敏，不附凭据、完整响应或完整会话文件。

---

Meterline stores connection metadata and normalized history locally, with no application analytics or custom upload service. Secrets entered in credential fields live in per-connection Keychain items, not exported templates. Background access is noninteractive; explicit saves/reauthorization trust only the app for app-owned items. Legacy GLM items remain available for compatibility.

Local session and log access is selected per source. Log scanning is opt-in, and only usage metadata is persisted; prompts, responses, code, and full sessions are not stored in the history database. Web login uses isolated temporary WebKit storage. CLI behavior remains subject to the original tool's own configuration. Paid Claude probes are disabled by default.

`connections.json` and `usage.sqlite` are owner-readable/writable local files. The SQLite database is not claimed to be encrypted. History defaults to 90 days. Provider values, estimates, currencies, local logs, and imported records remain distinct. Optional models.dev downloads contain no account credentials. Local notifications may contain connection labels and quota values when authorized by the user.
