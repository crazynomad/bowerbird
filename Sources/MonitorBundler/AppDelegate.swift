import AppKit
import BundlerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = LayoutStore()
    private var monitor: DisplayMonitor?
    private var undoPoint = UndoPoint()
    private var lastResult: String?
    private var lastEnvironmentKey = ""

    private var autoRestore: Bool {
        get { UserDefaults.standard.object(forKey: "autoRestore") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRestore") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Monitor Bundler")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !AX.isTrusted { AX.requestTrust() }
        if !SkyLight.isAvailable { Log.write("⚠️ SkyLight 私有接口不可用，Space 信息将缺失") }
        lastEnvironmentKey = Displays.currentEnvironment().key
        monitor = DisplayMonitor { [weak self] in self?.displaysSettled() }
        Log.write("启动，当前环境 \(lastEnvironmentKey)")
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let environment = Displays.currentEnvironment()
        let layout = store.load(environmentKey: environment.key)

        if !AX.isTrusted {
            menu.addItem(item("⚠️ 需要辅助功能权限…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        menu.addItem(info("当前环境：\(layout?.name ?? environment.suggestedName)（\(environment.displays.count) 块屏）"))
        if let layout {
            let fullScreen = layout.windows.filter(\.isFullScreen).count
            menu.addItem(info("已保存：\(layout.savedAt.formatted(date: .abbreviated, time: .shortened))，\(layout.windows.count) 个窗口（全屏 \(fullScreen)）"))
        } else {
            menu.addItem(info("此环境尚未保存布局"))
        }
        menu.addItem(.separator())

        menu.addItem(item("保存当前布局…", #selector(saveLayout)))
        menu.addItem(item("恢复布局", #selector(restoreLayout), enabled: layout != nil))
        menu.addItem(item("撤销上次恢复", #selector(undoRestore), enabled: !undoPoint.isEmpty))
        menu.addItem(.separator())

        let auto = item("显示器变化时自动恢复", #selector(toggleAutoRestore))
        auto.state = autoRestore ? .on : .off
        menu.addItem(auto)
        if let lastResult { menu.addItem(info("上次：\(lastResult)")) }
        menu.addItem(item("查看日志", #selector(openLog)))
        menu.addItem(item("打开布局文件夹", #selector(openLayoutFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 动作

    @objc private func saveLayout() {
        guard monitor?.isSettling != true else {
            alert("显示器配置刚发生变化", "macOS 可能正在临时挪动窗口，请等几秒再保存，以免存下被挤乱的布局。")
            return
        }
        let environment = Displays.currentEnvironment()
        let defaultName = store.load(environmentKey: environment.key)?.name ?? environment.suggestedName
        guard let name = askName(default: defaultName) else { return }

        let layout = Restorer.snapshot(of: environment, name: name)
        do {
            try store.save(layout)
            lastResult = "已保存「\(name)」\(layout.windows.count) 个窗口"
            Log.write("\(lastResult!)\n" + layout.windows.map { "  \($0.appName)「\($0.title)」 \($0.displayUUID.prefix(8))#\($0.spaceIndex)\($0.isFullScreen ? " 全屏" : "")" }.joined(separator: "\n"))
        } catch {
            alert("保存失败", error.localizedDescription)
        }
    }

    @objc private func restoreLayout() {
        let environment = Displays.currentEnvironment()
        guard let layout = store.load(environmentKey: environment.key) else { return }
        restore(layout, in: environment, trigger: "手动")
    }

    @objc private func undoRestore() {
        let report = Restorer.undo(undoPoint)
        undoPoint = UndoPoint()
        lastResult = "撤销：\(report.summary)"
        Log.write("撤销恢复：\(report.summary)\n\(report.details)")
    }

    @objc private func toggleAutoRestore() { autoRestore.toggle() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func openLayoutFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func openAccessibilitySettings() {
        AX.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - 自动恢复

    private func displaysSettled() {
        let environment = Displays.currentEnvironment()
        guard environment.key != lastEnvironmentKey else { return }
        lastEnvironmentKey = environment.key
        guard let layout = store.load(environmentKey: environment.key) else {
            Log.write("切换到未保存的环境 \(environment.key)")
            return
        }
        Log.write("切换到「\(layout.name)」")
        if autoRestore { restore(layout, in: environment, trigger: "自动") }
    }

    private func restore(_ layout: Layout, in environment: DisplayEnvironment, trigger: String) {
        let (report, undo) = Restorer.restore(layout, in: environment)
        if !undo.isEmpty { undoPoint = undo }
        lastResult = "\(trigger)恢复「\(layout.name)」：\(report.summary)"
        Log.write("\(lastResult!)\n\(report.details)")
    }

    // MARK: - 对话框

    private func askName(default name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "保存当前布局"
        alert.informativeText = "为这组显示器起个名字："
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
