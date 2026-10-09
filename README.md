# Monitor Bundler

macOS 菜单栏工具：按显示器组合（家里 / 公司）保存窗口布局，换环境后自动恢复。背景和调研见 [IDEAS.md](IDEAS.md)。

## 当前能力（阶段 1）

- 用显示器 UUID 集合识别环境，不依赖屏幕数量或排列。
- 保存所有 Space 上普通应用的窗口，包括非当前 Space 和原生全屏窗口。
- 恢复普通窗口的显示器、位置和尺寸，也能操作当前不可见 Space 上的窗口。原生全屏窗口暂时跳过（阶段 2）。
- 显示器变化稳定 3 秒后自动恢复；变化未稳定时拒绝保存，防止存下被挤乱的布局。
- 一键撤销上次恢复。

## 构建与运行

```bash
./scripts/build-app.sh            # 构建并签名 build/MonitorBundler.app
open build/MonitorBundler.app     # 首次运行需在 系统设置 → 隐私与安全性 → 辅助功能 中授权
swift test                        # 单元测试
```

调试用命令行（借用终端的辅助功能权限）：

```bash
swift build
.build/debug/MonitorBundler dump          # 列出环境和所有窗口
.build/debug/MonitorBundler save [名称]    # 保存当前布局
.build/debug/MonitorBundler restore       # 恢复
```

- 布局文件：`~/Library/Application Support/MonitorBundler/Layouts/`
- 日志：`~/Library/Logs/MonitorBundler.log`
- 私有接口集中在 `Sources/BundlerCore/Private.swift`，macOS 升级后若失效，先检查这里。
