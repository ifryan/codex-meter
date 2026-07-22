# Contributing

感谢你参与 Codex Meter。

## 开发环境

- macOS 14+
- Apple Command Line Tools
- 本机可用的 Codex CLI 或 Codex App

```sh
git clone https://github.com/ifryan/codex-meter.git
cd codex-meter
swift test
./build-app.sh
```

## 修改原则

- 将 app-server 协议、状态管理和几何算法保持为可单元测试的逻辑；
- 不要读取或持久化 Codex Token；
- 不要把用户的真实额度响应、账户信息或配置提交为 fixture；
- UI 修改应同时检查带刘海和无刘海布局；
- 新增第三方代码或资源时，必须记录来源和许可证；
- 保持默认状态只显示左侧百分比和右侧重置时间。

## 提交前检查

```sh
git diff --check
sh -n build-app.sh
swift test
./build-app.sh
```

Pull Request 请说明修改原因、用户影响、验证方式及任何协议兼容性变化。
