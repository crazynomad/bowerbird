import AppKit
import BundlerCore

/// 调试用命令行：
///   MonitorBundler dump            列出当前环境和所有窗口
///   MonitorBundler save [名称]      保存当前布局（与菜单栏共用存储）
///   MonitorBundler restore         按已保存布局恢复普通窗口
@MainActor
enum CLI {
    static func run(command: String, arguments: [String]) -> Int32 {
        guard AX.isTrusted else {
            print("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能")
            return 1
        }
        let environment = Displays.currentEnvironment()
        let store = LayoutStore()

        switch command {
        case "dump":
            print("环境 \(environment.suggestedName)  key=\(environment.key)")
            for display in environment.displays {
                print("  \(display.uuid.prefix(8)) \(display.name)\(display.isBuiltin ? "（内建）" : "") \(display.frame)")
            }
            for window in WindowCatalog.capture(in: environment).sorted(by: { ($0.displayUUID, $0.space?.index ?? 0, $0.windowID) < ($1.displayUUID, $1.space?.index ?? 0, $1.windowID) }) {
                let place = "\(window.displayUUID.prefix(8))#\(window.space?.index ?? 0)"
                print("  \(place) \(window.isFullScreen ? "全屏" : "    ") wid=\(window.windowID) \(Rect(window.frame)) \(window.label)")
            }
            return 0

        case "save":
            let name = arguments.first ?? store.load(environmentKey: environment.key)?.name ?? environment.suggestedName
            let layout = Restorer.snapshot(of: environment, name: name)
            do {
                try store.save(layout)
                print("已保存「\(name)」\(layout.windows.count) 个窗口 → \(store.directory.path)")
                return 0
            } catch {
                print("保存失败：\(error)")
                return 1
            }

        case "restore":
            guard let layout = store.load(environmentKey: environment.key) else {
                print("当前环境没有保存的布局")
                return 1
            }
            let (report, _) = Restorer.restore(layout, in: environment)
            print("恢复「\(layout.name)」：\(report.summary)\n\(report.details)")
            return report.failed.isEmpty ? 0 : 1

        default:
            print("未知命令 \(command)。可用：dump / save [名称] / restore")
            return 2
        }
    }
}
