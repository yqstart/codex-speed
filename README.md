# Codex Speed

独立的 macOS 悬浮球，显示 Codex 的生成速率 `token/s`。拖动浮球可移动位置。右键可以查看会话或退出。

## 打开应用

在 Finder 中打开生成的 `dist/Codex Speed.app`。需要 macOS 14 或更新版本及对应架构的构建产物。

有 Swift 工具链时，可以在项目目录构建。

```sh
./scripts/build-app.sh
```

## 读数

悬浮球读取本机 Codex 会话日志的模型、事件时间和输出用量，并用本地索引显示会话名。并行运行时，右键菜单列出打开菜单时各会话的模型和读数。点某一项可固定到该会话，结束后球上显示 `—`。选择「自动显示最近活跃」可恢复优先跟随桌面端的最近活跃会话。

`≈` 表示根据同一会话、同一模型的近期请求估算的速度。Codex 写入本次用量后，会显示该次请求的平均速度。空闲或样本不足时显示 `—`。

悬浮球与从日志取数的思路参考 [Agent Speed](https://github.com/zoefix/agent-speed/blob/bbe690a233c9ec4c9bac1e6793b065af9ab04905/spec/METRICS.md)。
