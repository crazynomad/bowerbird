# Bowerbird

macOS 菜单栏工具：按显示器组合（家里 / 公司）保存窗口布局，换环境后自动恢复。背景和调研见 [IDEAS.md](IDEAS.md)。

## 当前能力（阶段 2）

- 用显示器 UUID 集合识别环境，不依赖屏幕数量或排列。
- 恢复普通窗口的显示器、位置和尺寸，包括当前不可见 Space 上的窗口。
- 恢复原生全屏窗口所在的显示器和 Space 顺序，只重排必须动的窗口。
- 三级布局来源：📌 钉住 → 自动记录（稳定时每分钟一次）→ 首次进入时按默认规则从上一个环境推导。
- 显示器变化稳定 3 秒后自动恢复；变化未稳定时拒绝钉住，自动记录也会跳过。恢复途中显示器再变化会立即中止。
- 暂时断开（拔线只剩部分屏）以及接回原环境时不接管，交给 macOS 原生恢复，只把差异写入日志。
- 一键撤销上次恢复，全屏状态和 Space 顺序也一并撤回。
- 恢复后每块屏回到离开时显示的那一页，键盘焦点也一并还原。
- 恢复进行中菜单栏小鸟闪烁，悬停提示和菜单显示当前步骤。
- 设置窗口检测辅助功能权限、Space 自动重排、开机自动启动，并提供一键操作；缺少必需权限时自动弹出，图标变为警告。

> 需关闭 系统设置 → 桌面与程序坞 →「根据最近的使用情况自动重新排列空间」，否则 Space 顺序会被系统打乱。菜单会检测并提示。

## 构建与运行

```bash
./scripts/build-app.sh --install  # 构建、签名并安装到 /Applications，然后启动
swift test                        # 单元测试
```

首次启动会弹出设置窗口，按提示授予辅助功能权限即可。开机自动启动登记的是 App 所在路径，所以日常应从 `/Applications` 运行；不带 `--install` 时只构建到 `build/Bowerbird.app`。

调试用命令行（借用终端的辅助功能权限）：

```bash
swift build
.build/debug/Bowerbird dump          # 列出环境和所有窗口
.build/debug/Bowerbird pin [名称]     # 钉住当前布局
.build/debug/Bowerbird learn         # 写入一次自动记录
.build/debug/Bowerbird restore [布局.json]   # 恢复（默认：钉住 → 自动记录）
.build/debug/Bowerbird derive <布局.json>    # 按默认规则推导到当前环境，输出 JSON
.build/debug/Bowerbird diff [布局.json]      # 只读对比当前窗口与布局
```

- 布局文件：`~/Library/Application Support/Bowerbird/Layouts/`
- 日志：`~/Library/Logs/Bowerbird.log`
- 私有接口集中在 `Sources/BowerbirdCore/Private.swift`，macOS 升级后若失效，先检查这里。
