# Contributing

感谢你参与 Codex Meter。架构、认证边界和新增适配器步骤见[来源开发指南](docs/provider-development.md)，实际覆盖与验证状态见[来源矩阵](docs/providers.md)。

## 开发环境

- macOS 14+，Apple Command Line Tools。
- 按要修改的来源准备 CLI、合成响应或自己的测试账户；Codex CLI 不是所有适配器的前提。

```sh
git clone https://github.com/ifryan/codex-meter.git
cd codex-meter
```

## 修改原则

- 在来源层实现认证、请求和解析，返回标准化快照；不要继续向 AppDelegate 添加专用来源状态。
- 稳定区分来源 ID、账户 UUID 和凭据修订。新增来源不自动占用刘海常驻位置。
- 内置接口只读，付费探测必须有明确开关；不为了统计改写其他工具登录态或路由。
- 密钥只存钥匙串，非敏感配置才可导出；不提交真实账户响应、Cookie、Token 或完整日志为 fixture。
- 不用零值表示未知；不把计价估算当账单，不混合币种或重复统计两个数据源。
- 更新来源矩阵和认证说明；无法实际核验的能力明确记录，不只添加名称和图标。
- 借用第三方代码或资源时保留原许可和归属，更新 NOTICE。

## 检查与 PR

根据实际改动及已授权范围选择检查，记录真实结果。建议的命令包括：

```sh
git diff --check
sh -n build-app.sh
swift test
./build-app.sh
```

新核心样例覆盖字段映射、未知值、MiniMax 无限／耗尽、Kimi 多窗口、账户隔离、计价缺失、Codex 增量、CSV 和历史去重。真实账户与原生 UI 验收需要单独完成，构建通过不能替代它们。

PR 请说明：用户问题、最终行为、涉及来源／区域、配置迁移、实际检查和未执行项。只提交本次改动，不附密钥、私有数据或本地构建产物。

## 合成演示

需要本机查看界面时可使用演示模式：

```sh
./build-app.sh
CODEX_METER_DEMO=1 "dist/Codex Meter.app/Contents/MacOS/CodexMeter"
```

演示只创建内存中的三个合成账户，不启动 CLI、不读取钥匙串或历史、不发额度请求，也不保存配置。界面变动的验收应覆盖刘海／无刘海、1–3 常驻项、第四个连接、长名称、不同指标、多账户、拖动、设置和统计窗口。
