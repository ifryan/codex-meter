# Meterline

[English](README.en.md) · [来源矩阵](docs/providers.md) · [迁移说明](docs/migration.md) · [隐私](PRIVACY.md) · [安全](SECURITY.md) · [更新日志](CHANGELOG.md)

[![CI](https://github.com/ifryan/meterline/actions/workflows/ci.yml/badge.svg)](https://github.com/ifryan/meterline/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)

macOS 原生的 AI 用量监控工具。订阅额度、重置时间、API 余额、Token 和费用都显示在 MacBook 刘海上，没有刘海的屏幕则显示为顶部中央的胶囊。

可以同时监控多家服务的多个账户，界面支持简体中文和英文，跟随系统语言。只有 Codex 本机模式才需要安装 Codex CLI。

项目原名 Codex Meter，从旧版升级时会自动迁移数据，详见[迁移说明](docs/migration.md)。

这是非官方社区项目，与各服务商没有关联，也未获其背书。相关名称和商标属于各自权利人。

## 功能

- **刘海常驻**：最多固定 3 个连接，每个连接可选主指标。悬停查看全部已启用的连接，拖动标题调整顺序。
- **多账户**：同一来源可以添加多个命名账户，各自有独立的凭据、地区、刷新间隔和错误状态。
- **多种认证**：本机登录态、独立 OAuth 文件、API Key、网页登录 Cookie、Copilot 设备授权，可用方式取决于来源。
- **自定义来源**：用表单配置 HTTP 查询和 JSON 字段映射，能接入没有内置的服务。不执行任意脚本。
- **用量统计**：独立窗口按今天、7 天、30 天查看趋势，可按工具、账户或模型分组。本地日志采集默认关闭。
- **额度重置通知**：检测到额度重置时发送 macOS 本地通知。

显示规则比较保守：

- 只有拿到总量的指标才显示进度。
- 查询失败时保留旧值并标明时间，不会显示成 0。
- 价格未知时显示未知，不当作免费。
- 不同币种不相加。本地日志、工具导出和服务商账单也分开统计，避免同一笔用量算两次。

## 支持的来源

注册表共 41 个条目，其中包含地区变体和模板，所以这不等于 41 家服务，也不代表都已用真实账户验证过。每个来源的读取路径、认证前提和限制见[来源矩阵](docs/providers.md)。

| 类别 | 来源 |
| --- | --- |
| 订阅 | Codex / ChatGPT、Claude、GitHub Copilot、Gemini CLI、Antigravity、Cursor、Windsurf、Kiro、Factory / Droid、Warp |
| Coding Plan | GLM（国内、团队）、Z.ai、Kimi Code、MiniMax、OpenCode Go、Command Code、阿里 Coding Plan、火山方舟、腾讯云 Token Plan（企业）、ZenMux |
| API 余额 | DeepSeek、Moonshot、OpenRouter、StepFun、Novita AI、AiHubMix、SiliconFlow（旧余额接口已停用，目前不能保证读到余额） |
| 组织用量 | OpenAI API、Anthropic API（都需要管理员 Key） |
| 已有工具 | Magpie（本机 HTTP API）、CC Switch（只读用量导出文件） |
| 自定义 | 自定义 HTTP / JSON，以及 New API / One API、Sub2API 模板 |

本地日志采集支持 Codex、Claude、Gemini CLI、OpenCode 和 Pi；Kimi、MiniMax 只支持结构兼容的 JSONL。

## 项目状态

项目处于 1.0 之前，配置和界面还可能变化。

- **版本**：多来源监控目前只在 `main` 分支上，还没有发布版本。最新的 [v0.2.0](https://github.com/ifryan/meterline/releases/tag/v0.2.0) 早于这次改动，也没有附带安装包。下一个版本起，[Releases](https://github.com/ifryan/meterline/releases) 会提供 `.dmg`。
- **自动检查**：CI 在每次推送时运行 `swift test` 和 Universal 2 构建。
- **尚未完成**：逐个来源的真实账户核验、新界面的完整验收。这些接口大多不是服务商公开承诺的稳定契约，返回格式变化后解析可能失效。遇到这种情况欢迎[提 Issue](https://github.com/ifryan/meterline/issues)。

新界面的截图会在验收后补上。

## 安装

需要 macOS 14 或更高版本（Apple Silicon 或 Intel）。

### 下载安装包

从 [Releases](https://github.com/ifryan/meterline/releases) 下载 `.dmg`，把 Meterline 拖到“应用程序”。

如果该版本没有经过 Apple 公证（发布说明里会写明），首次打开会被系统拦截。先打开一次，再到“系统设置 → 隐私与安全性”点击“仍要打开”。如果提示应用已损坏，运行：

```sh
xattr -dr com.apple.quarantine /Applications/Meterline.app
```

### 从源码构建

需要 Apple Command Line Tools。

```sh
git clone https://github.com/ifryan/meterline.git
cd meterline
./build-app.sh
open "dist/Meterline.app"
```

确认运行正常后，可以把应用拖到 `/Applications`，再在刘海菜单中开启“开机自动启动”。

默认构建使用 ad-hoc 签名，只适合本机使用。重新构建后应用身份可能变化，如果钥匙串无法读取已保存的凭据，在连接编辑器中重新授权即可。

构建选项：

```sh
# 只构建 Apple Silicon，速度更快
ARCHS=arm64 ./build-app.sh

# 使用 Developer ID 签名
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
```

想先看效果，可以用演示模式。它只创建内存中的合成账户，不读取钥匙串和历史，不发额度请求，也不保存配置：

```sh
METERLINE_DEMO=1 "dist/Meterline.app/Contents/MacOS/Meterline"
```

## 开始使用

新安装从空的连接列表开始。

1. 点击刘海或顶部胶囊，选择“连接设置…”。
2. 在“添加连接”中选择来源，配置本机账户、独立凭据或网页登录。
3. 需要的话先运行“连接预览”查看查询结果，然后保存启用。预览不会保存配置。
4. 对要常驻的连接开启“固定到刘海”，并选择主指标。
5. 要看历史趋势，打开“用量统计… → 采集与价格设置”，启用日志采集，并设置目录和价格。

几个来源的特殊行为：

- **Codex**：本机模式通过 `codex app-server --stdio` 读取，不需要粘贴 Token。额外账户使用各自的 OAuth 文件或 Token。
- **Claude**：优先读 usage 接口，不消耗推理额度。只有在连接中开启“允许消耗少量推理额度的探测”后，才会发送最小推理请求读取响应头。
- **GLM**：旧版 Key 可以继续使用，也可以用“迁移旧 GLM 凭据”复制到新条目，旧条目不会删除。

从旧版本升级请看[迁移说明](docs/migration.md)。

Codex 装在非标准位置时，可以在连接里选择可执行文件，或者设置路径后重启应用：

```sh
defaults write io.github.ifryan.meterline codexExecutablePath /absolute/path/to/codex
```

## 自定义来源

内置列表里没有的服务，只要有返回 JSON 的 HTTP 接口，通常都能接入：

- 请求支持 GET 和 POST。HTTP 明文地址需要单独开启，重定向会被拒绝。
- 认证请求头使用 `${token}`、`${cookie}`、`${userID}` 占位符，实际值填在安全凭据栏，保存在钥匙串里。不要把密钥写进 URL、普通请求头或请求体，这些内容会随模板导出。
- 字段路径写成 `data.balance` 或 `items[0].remaining`，并支持数组行、数值缩放、剩余或已用方向、重置时间。

New API / One API 和 Sub2API 有现成的起始模板。模板不包含凭据，导入后默认停用，配置好认证再启用。

## 数据与隐私

没有账户系统、分析或上传历史的后台。网络请求只发往你配置的来源；只有主动点击“从 models.dev 补充价格”时才会访问 models.dev，且不带账户凭据或会话内容。

本地文件位于 `~/Library/Application Support/Meterline/`：

| 位置 | 内容 |
| --- | --- |
| `connections.json` | 非敏感的连接配置、排列、日志目录、账户绑定和价格 |
| `usage.sqlite` | 标准化用量事件、额度快照和导入进度，默认保留 90 天，可设为 30 到 730 天。数据库未加密，靠文件权限保护 |
| 钥匙串 `Meterline Connections` | 每个连接独立的 Key、Token 和 Cookie |

历史只保存用量字段，不保存提示词、回复、代码或完整会话。Kiro 的 CLI 查询可能产生空会话，其他本机工具也会按自身规则联网和记录。完整边界见[隐私说明](PRIVACY.md)。

API 单价估算的费用不等于订阅的实际付款。

## 参与贡献

现在最有帮助的几件事：

1. 用自己的账户核验某个来源，并把结果（不含账户信息）反馈到 Issue 或更新[来源矩阵](docs/providers.md)。
2. 补充新来源的适配器，步骤见[适配器指南](docs/provider-development.md)。
3. 在不同屏幕和语言下验收界面并提供截图，可以用演示模式，避免暴露真实账户。
4. 校对现有翻译，或添加新语言。

开始前请读 [CONTRIBUTING.md](CONTRIBUTING.md)。常用检查：

```sh
git diff --check
sh -n build-app.sh
swift test
./build-app.sh
```

`./build-app.sh` 只需要 Command Line Tools。`swift test` 依赖 XCTest，需要安装完整 Xcode；没有 Xcode 时可以交给 CI 验证。

新增或修改界面文案的方法，以及如何添加新语言，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

发布新版本时推送 `vX.Y.Z` tag，CI 会生成带 `.dmg` 的 Release 草稿，确认后手动发布。

Issue 和 PR 里不要附 Token、Cookie、完整响应或会话文件。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证与致谢

使用 [GPL-3.0-only](LICENSE) 发布。

刘海设计参考了 Atoll 和 boring.notch，来源架构和接口参考了 CodexBar、Magpie、CC Switch 以及服务商公开协议。详细归属和 Ubuntu Mono 字体许可见 [NOTICE.md](NOTICE.md)。
