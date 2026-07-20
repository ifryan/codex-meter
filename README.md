# Codex Meter

一个原生 macOS 刘海工具，在屏幕顶部正中央显示 Codex 主额度的剩余百分比。带刘海的 MacBook 上，黑色浮层与物理刘海衔接，并把可读内容展示在刘海下沿；外接无刘海屏幕则显示为顶部中央胶囊。

鼠标移入刘海下沿时会自动展开详情，移出后自动收起。点击仍可打开操作菜单。

展开后可查看：

- 主 Codex 额度及重置时间
- 独立模型额度（如果账户返回）
- 可用重置卡数量
- 当前订阅计划和最近更新时间

数据通过本机 `codex app-server` 读取，复用 Codex 当前登录态；应用不会读取、保存或上传访问令牌。默认每 5 分钟刷新，也可以手动刷新。

## 构建

```sh
chmod +x build-app.sh
./build-app.sh
open "dist/Codex Meter.app"
```

要求 macOS 13 或更高版本、Apple Command Line Tools，以及可用的 Codex CLI / Codex 桌面应用。构建脚本直接调用 `swiftc`，不依赖 Xcode 工程。
