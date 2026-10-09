import AppKit
import BundlerCore

/// 调试用命令行（与菜单栏共用存储）：
///   MonitorBundler dump                 列出当前环境和所有窗口
///   MonitorBundler pin [名称]            钉住当前布局
///   MonitorBundler learn                写入一次自动记录
///   MonitorBundler restore [布局.json]   恢复（默认按 钉住 → 自动记录 选择）
///   MonitorBundler derive <布局.json>    按默认规则把某布局推导到当前环境，输出 JSON
///   MonitorBundler diff [布局.json]      只读对比当前窗口与布局（默认：钉住 → 自动记录）
@MainActor
enum CLI {
    static func run(command: String, arguments: [String]) async -> Int32 {
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

        case "pin", "learn":
            let kind: LayoutKind = command == "pin" ? .pinned : .learned
            let name = arguments.first ?? store.load(environmentKey: environment.key, kind: kind)?.name ?? environment.suggestedName
            let layout = Restorer.snapshot(of: environment, name: name)
            do {
                try store.save(layout, kind: kind)
                print("已保存「\(name)」\(layout.windows.count) 个窗口（\(command)）→ \(store.directory.path)")
                return 0
            } catch {
                print("保存失败：\(error)")
                return 1
            }

        case "restore":
            let layout: Layout
            if let path = arguments.first {
                guard let loaded = load(path) else { return 1 }
                layout = loaded
            } else {
                guard let (resolved, source) = LayoutResolver.resolve(for: environment, previousEnvironmentKey: nil, store: store) else {
                    print("当前环境没有保存的布局")
                    return 1
                }
                print("使用\(source.label)布局")
                layout = resolved
            }
            let started = Date()
            let report = await Restorer.restore(layout, in: environment)
            print("恢复「\(layout.name)」：\(report.summary)（\(String(format: "%.1f", Date().timeIntervalSince(started)))s）\n\(report.details)")
            return report.failed.isEmpty ? 0 : 1

        case "derive":
            guard let path = arguments.first, let source = load(path),
                  let data = try? LayoutStore.encode(LayoutMapper.derive(from: source, to: environment)) else {
                print("用法：derive <布局.json>")
                return 2
            }
            FileHandle.standardOutput.write(data)
            return 0

        case "diff":
            let layout: Layout
            if let path = arguments.first {
                guard let loaded = load(path) else { return 1 }
                layout = loaded
            } else {
                guard let (resolved, _) = LayoutResolver.resolve(for: environment, previousEnvironmentKey: nil, store: store) else {
                    print("当前环境没有保存的布局")
                    return 1
                }
                layout = resolved
            }
            let differences = Restorer.differences(from: layout, in: environment)
            print("与「\(layout.name)」相差 \(differences.count) 处" + differences.map { "\n  - \($0)" }.joined())
            return 0

        default:
            print("未知命令 \(command)。可用：dump / pin [名称] / learn / restore [布局.json] / derive <布局.json> / diff [布局.json]")
            return 2
        }
    }

    private static func load(_ path: String) -> Layout? {
        do {
            return try LayoutStore.load(from: URL(fileURLWithPath: path))
        } catch {
            print("读取 \(path) 失败：\(error)")
            return nil
        }
    }
}
