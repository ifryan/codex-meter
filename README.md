# Codex Meter

[English](README.en.md) · [隐私说明](PRIVACY.md) · [安全策略](SECURITY.md)

[![CI](https://github.com/ifryan/codex-meter/actions/workflows/ci.yml/badge.svg)](https://github.com/ifryan/codex-meter/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)

Codex Meter 是一个轻量的原生 macOS 刘海工具，在物理刘海两侧持续展示本机 Codex 账户的额度状态。

- 左侧：主额度剩余百分比
- 右侧：距离重置的剩余时间，使用 `D`、`H`、`M`
- 刘海边缘：按额度充足程度显示绿、黄、红渐变进度线
- 鼠标悬停：展开一行重置卡信息，多张卡用 `/` 分隔
- 点击：查看全部额度窗口、更新时间、手动刷新、开机启动和退出选项

> [!IMPORTANT]
> 这是一个非官方社区项目，与 OpenAI 没有关联或背书。Codex 是 OpenAI 的产品和商标。

## 工作方式

Codex Meter 不实现自己的登录系统，也不要求用户向应用粘贴 Token。它会启动本机可用的：

```text
codex app-server --stdio
```

然后通过本地 JSON-RPC 方法读取当前 Codex 登录态对应的限额数据。因此：

- Codex CLI、Codex App 或 ChatGPT App 必须已经登录；
- 如果账户由 auth.js 或其他工具同步到本机 Codex 登录态，只要 `codex app-server` 能识别，该账户就能正常显示；
- 应用本身不读取或保存访问令牌；
- 用量快照只保存在内存中，退出应用后不会保留；
- 实际网络访问和身份验证由本机 Codex 进程完成。

完整说明见 [PRIVACY.md](PRIVACY.md)。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon 或 Intel Mac
- Apple Command Line Tools
- 已安装并登录的 Codex CLI、Codex App 或 ChatGPT App

物理刘海屏幕会使用刘海模式；外接无刘海屏幕会退化为顶部中央胶囊。

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

## 数据刷新与错误状态

- 启动后立即读取一次；
- 每 5 分钟自动刷新；
- 从睡眠状态恢复后立即刷新；
- 菜单支持手动刷新；
- 刷新失败时保留最后一次成功数据，并在菜单中明确标记为旧数据；
- 没有成功数据时显示 `--%` 和 `--H`，不会把读取失败误画成 0% 额度。

## 项目结构

```text
Sources/CodexMeter/
├── Domain.swift             数据模型、Codable 协议和格式化
├── CodexUsageClient.swift   Codex 子进程与 JSON-RPC transport
├── NotchUI.swift            刘海绘制、路径进度和窗口控制
├── AppDelegate.swift        状态机、刷新、菜单和登录项
└── CodexMeterApp.swift      应用入口

Tests/CodexMeterTests/       协议、时间和路径算法测试
Resources/Fonts/             Ubuntu Mono 及其许可证
```

应用依赖 Codex 当前仍处于实验阶段的 app-server 接口。升级 Codex 后如果读取失败，请先在菜单中查看错误信息，并在 Issue 中附上 Codex 版本号，但不要提交 Token、Cookie 或完整配置文件。

## 开发

```sh
swift test
./build-app.sh
```

提交前应至少通过：

```sh
git diff --check
sh -n build-app.sh
swift test
./build-app.sh
```

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 路线图

- 可视化选择 Codex 可执行文件和目标屏幕
- Codex app-server 版本兼容矩阵
- Developer ID 签名、公证和自动 Release
- 更多语言和 VoiceOver 支持

## 许可证与致谢

Codex Meter 使用 [GPL-3.0-only](LICENSE) 发布。

界面设计参考了 [Atoll](https://github.com/Ebullioscopic/Atoll) 和 [boring.notch](https://github.com/TheBoredTeam/boring.notch)。项目内置 Ubuntu Mono，字体许可证见 [Resources/Fonts/LICENCE.txt](Resources/Fonts/LICENCE.txt)。更多归属信息见 [NOTICE.md](NOTICE.md)。
