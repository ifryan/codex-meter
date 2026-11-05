# Codex Meter

[English](README.en.md) · [来源矩阵](docs/providers.md) · [迁移说明](docs/migration.md) · [隐私](PRIVACY.md) · [安全](SECURITY.md)

[![CI](https://github.com/ifryan/codex-meter/actions/workflows/ci.yml/badge.svg)](https://github.com/ifryan/codex-meter/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)

原生 macOS AI 用量监控工具：在刘海或顶部胶囊中查看订阅额度、重置时间、API 余额、Token 和费用。

- 来源注册表和独立账户：支持同一来源的多个命名账户／Key、地区变体和各自认证。
- 最多固定 3 项常驻，选择每项主指标；悬停查看全部已启用连接，拖动标题调整顺序。
- 百分比、余额、Token 和费用按实际单位显示；只有具备总量的指标才显示进度。
- 内置覆盖 Codex、Claude、GLM／Z.ai、Kimi、MiniMax、Copilot、Gemini、Cursor 等多类读取路径，具体能力和限制见[来源矩阵](docs/providers.md)。目录条目数不是已验证服务数量。
- 自定义 HTTP 查询表单和 JSON 字段映射，支持多指标、数组、单位缩放与模板导入导出。
- 统一连接设置，支持本机登录态、独立 OAuth 文件、API Key、网页 Cookie 和 Copilot 设备授权。
- 独立统计窗口，提供今天／7 天／30 天的汇总、趋势和工具／账户／模型分组。
- 本地日志默认不采集，启用后增量读取；未知账户保留“未归属”，未知价格不视为免费。
- 服务商日账单、本地日志、已有工具导出分开；费用口径与币种分开，组织账单按 UTC 日展示。
- 各连接独立刷新，默认 5 分钟；失败保留带时间的旧值，限流退避，换凭据隔离旧请求。
- 后台凭据读取不主动弹授权，密钥保存在本机钥匙串；付费推理探测默认关闭。

2026-10-27 已完成 Universal 2 构建、签名与安装文件核对，并替换本机已安装应用。单元测试、各来源真实账户核验及原生界面验收尚未执行，详情见[来源矩阵](docs/providers.md)。新界面截图待原生验收后补充。

这是非官方社区项目，与服务商没有关联或背书。Codex 等名称和商标属于各自权利人。

## 开始使用

1. 点击刘海或顶部胶囊，选择“连接设置…”。
2. 从“添加连接”选择来源，配置当前本机账户、独立凭据或网页登录。
3. 可主动执行“连接预览”检查当前查询结果，再保存启用；预览不保存配置。
4. 为需要常驻的连接开启“固定到刘海”，最多 3 项；在编辑器中选择主指标。
5. 打开“用量统计… → 采集与价格设置”，按需启用日志、设置目录与价格。

Codex 当前 CLI 模式仍通过 `codex app-server --stdio` 读取，不要求粘贴 Token。额外 Codex 账户可选择自己的 OAuth 文件。Claude 优先读取 usage API；只有用户开启“允许消耗少量推理额度的探测”后才使用计费响应头。

旧 GLM Key 可以继续读取，也可在连接编辑器中点击“迁移旧 GLM 凭据”后保存至新账户条目。旧条目不会删除。完整过程见[迁移说明](docs/migration.md)，旧手工配置细节保存在[历史认证说明](docs/legacy-authentication.md)。

## 自定义来源与已有工具

普通来源只需填写查询 URL、请求头和字段映射。认证请求头使用 `${token}`、`${cookie}`、`${userID}`；凭据填入安全凭据栏。字段支持 `data.balance`、`items[0].remaining`、数组行、缩放、剩余／已用方向及重置时间。

支持 New API／One API、Sub2API 起始模板。模板导入默认停用，用户配置认证后启用。不要把密钥填入 URL、普通请求头常量或请求体。没有任意脚本或自建模型代理。

Magpie 连接读取其 quotas／usage API；CC Switch 连接只读用户指定的 CSV／JSON 导出文件，不读取其密钥库。已有工具数据不与本地日志直接相加。具体格式见[贡献指南](docs/provider-development.md)。

## 系统要求

- macOS 14 或更高版本，Apple Silicon 或 Intel Mac。
- 从源码构建需要 Apple Command Line Tools。
- CLI、本机应用、API Key、Cookie 或管理 Key 按所选来源要求配置，Codex CLI 不是所有来源的前提。

物理刘海屏使用刘海模式；其他屏幕退化为顶部中央胶囊。

## 从源码安装

```sh
git clone https://github.com/ifryan/codex-meter.git
cd codex-meter
./build-app.sh
open "dist/Codex Meter.app"
```

默认构建 Universal 2 应用，输出路径为：

```text
dist/Codex Meter.app
```

确认运行正常后，可以将应用拖入 `/Applications`。点击刘海后，在菜单中选择“开机自动启动”即可注册登录项。

当前源码构建使用 ad-hoc 签名，仅适合本机开发。公开二进制只有在完成 Developer ID 签名和 Apple 公证后才应发布。

### 自定义构建

只构建 Apple Silicon：

```sh
ARCHS=arm64 ./build-app.sh
```

使用 Developer ID 签名：

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
```

如果 Codex 安装在非标准位置，可以保存自定义路径后重启应用：

```sh
defaults write io.github.ifryan.codexmeter codexExecutablePath /absolute/path/to/codex
```

开发时也可以直接运行可执行文件并临时覆盖：

```sh
CODEX_METER_CODEX_PATH=/absolute/path/to/codex \
  "dist/Codex Meter.app/Contents/MacOS/CodexMeter"
```

## 数据、历史与价格

配置和历史位于 `~/Library/Application Support/CodexMeter/`：

- `connections.json`：非敏感连接配置、排列、日志目录、账户绑定和价格。
- `usage.sqlite`：标准化用量事件、额度快照与增量导入位置，默认保留 90 天。
- 钥匙串 `CodexMeter Connections`：每个连接 UUID 对应独立的安全凭据；旧专属条目兼容读取。

统计窗口使用本机时区。模型精确匹配，支持手动价格和主动从 models.dev 补充目录价格；无价格或缺少相关缓存价格时保持未知。API 单价估算不代表订阅的实际付款。

应用只保存用量字段，不保存提示词、回复、代码或完整会话。完整存储和网络边界见[隐私说明](PRIVACY.md)。

## 开发与贡献

来源定义、账户、获取策略和展示数据分层。新增适配器不需要继续修改三家专用 UI 或 AppDelegate 状态。阅读[适配器指南](docs/provider-development.md)和[CONTRIBUTING.md](CONTRIBUTING.md)。

需要验证时可运行：

```sh
swift test
./build-app.sh
```

新核心样例检查在 `Tests/CodexMeterTests/MonitoringTests.swift`。构建、自动检查、真实账户与界面验收需要分别记录；不要在 Issue 中附 Token、Cookie 或完整会话文件。

## 许可证与致谢

使用 [GPL-3.0-only](LICENSE) 发布。设计参考 Atoll 和 boring.notch；来源架构与接口参考 CodexBar、Magpie、CC Switch 及服务商公开协议。Ubuntu Mono 字体许可和详细归属见 [NOTICE.md](NOTICE.md)。
