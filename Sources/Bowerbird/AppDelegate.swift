import AppKit
import BowerbirdCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 显示器稳定这么久之后才自动记录，确保 macOS 的挤压和本工具的恢复都已结束
    private static let learnAfterStable: TimeInterval = 30
    private static let learnInterval: TimeInterval = 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = LayoutStore()
    private var monitor: DisplayMonitor?
    private var learnTimer: Timer?
    /// 恢复前的完整布局；撤销 = 把它当目标再恢复一次，全屏和 Space 顺序也能撤回
    private var undoLayout: Layout?
    private var isRestoring = false
    /// 恢复期间显示器又稳定到新状态，待恢复结束后补处理
    private var settledWhileRestoring = false
    private var lastResult: String?
    private var lastEnvironment = DisplayEnvironment(displays: [])
    private var transitions = TransitionTracker()

    private var autoRestore: Bool {
        get { UserDefaults.standard.object(forKey: "autoRestore") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRestore") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Bowerbird")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !AX.isTrusted { AX.requestTrust() }
        if !SkyLight.isAvailable { Log.write("⚠️ SkyLight 私有接口不可用，Space 信息将缺失") }
        lastEnvironment = Displays.currentEnvironment()
        monitor = DisplayMonitor { [weak self] in self?.displaysSettled() }
        learnTimer = Timer.scheduledTimer(withTimeInterval: Self.learnInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.learnIfStable() }
        }
        Log.write("启动，当前环境 \(lastEnvironment.key)")
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let environment = Displays.currentEnvironment()
        let pinned = store.load(environmentKey: environment.key, kind: .pinned)
        let learned = store.load(environmentKey: environment.key, kind: .learned)

        if !AX.isTrusted {
            menu.addItem(item("⚠️ 需要辅助功能权限…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        if MissionControl.rearrangesSpacesAutomatically {
            menu.addItem(item("⚠️ 系统会自动重排 Space，顺序无法保持…", #selector(openDesktopSettings)))
            menu.addItem(.separator())
        }
        let environmentName = pinned?.name ?? learned?.name ?? environment.suggestedName
        menu.addItem(info("当前环境：\(environmentName)（\(environment.displays.count) 块屏）"))
        if let pinned { menu.addItem(info("📌 钉住：\(describe(pinned))")) }
        if let learned { menu.addItem(info("自动记录：\(describe(learned))")) }
        if pinned == nil && learned == nil { menu.addItem(info("此环境暂无布局，稳定 \(Int(Self.learnAfterStable))s 后自动记录")) }
        if let origin = transitions.disconnectedFrom {
            menu.addItem(info("暂时断开中：接回「\(name(of: origin))」时交给 macOS 恢复"))
        }
        menu.addItem(.separator())

        if isRestoring {
            menu.addItem(info("正在恢复…"))
        } else {
            menu.addItem(item("恢复布局", #selector(restoreLayout), enabled: pinned != nil || learned != nil))
            menu.addItem(item("撤销上次恢复", #selector(undoRestore), enabled: undoLayout != nil))
        }
        menu.addItem(item("钉住当前布局…", #selector(pinLayout)))
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

    private func describe(_ layout: Layout) -> String {
        let fullScreen = layout.windows.filter(\.isFullScreen).count
        return "\(layout.savedAt.formatted(date: .omitted, time: .shortened))，\(layout.windows.count) 个窗口（全屏 \(fullScreen)）"
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

    @objc private func pinLayout() {
        guard monitor?.isSettling != true, !isRestoring else {
            alert("显示器配置刚发生变化", "macOS 可能正在临时挪动窗口，请等几秒再钉住，以免存下被挤乱的布局。")
            return
        }
        let environment = Displays.currentEnvironment()
        let defaultName = store.load(environmentKey: environment.key, kind: .pinned)?.name
            ?? store.load(environmentKey: environment.key, kind: .learned)?.name
            ?? environment.suggestedName
        guard let name = askName(default: defaultName) else { return }

        let layout = Restorer.snapshot(of: environment, name: name)
        do {
            try store.save(layout, kind: .pinned)
            lastResult = "已钉住「\(name)」\(layout.windows.count) 个窗口"
            Log.write("\(lastResult!)\n" + layout.windows.map { "  \($0.appName)「\($0.title)」 \($0.displayUUID.prefix(8))#\($0.spaceIndex)\($0.isFullScreen ? " 全屏" : "")" }.joined(separator: "\n"))
        } catch {
            alert("保存失败", error.localizedDescription)
        }
    }

    @objc private func restoreLayout() {
        let environment = Displays.currentEnvironment()
        guard let (layout, source) = LayoutResolver.resolve(for: environment, previousEnvironmentKey: nil, store: store) else { return }
        Task { await restore(layout, source: source, in: environment, trigger: "手动") }
    }

    @objc private func undoRestore() {
        guard let undoLayout else { return }
        self.undoLayout = nil
        Task { await restore(undoLayout, source: nil, in: Displays.currentEnvironment(), trigger: "撤销", keepUndo: false) }
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

    @objc private func openDesktopSettings() {
        alert("请关闭自动重排 Space", "系统设置 → 桌面与程序坞 → 调度中心 → 关闭「根据最近的使用情况自动重新排列空间」。")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }

    // MARK: - 自动恢复与自动记录

    private func displaysSettled() {
        guard !isRestoring else {
            settledWhileRestoring = true
            return
        }
        let environment = Displays.currentEnvironment()
        guard environment.key != lastEnvironment.key else { return }
        let transition = transitions.transition(from: lastEnvironment, to: environment)
        lastEnvironment = environment

        switch transition {
        case .disconnect:
            let origin = transitions.disconnectedFrom.map(name(of:)) ?? "?"
            lastResult = "暂时断开（原环境「\(origin)」），不接管"
            Log.write(lastResult!)

        case .reconnect:
            lastResult = "重新连上「\(name(of: environment))」，交给 macOS 恢复"
            Log.write(lastResult!)
            Task { await checkNativeRestore(of: environment) }

        case .switched(let deriveFrom):
            guard let (layout, source) = LayoutResolver.resolve(for: environment, previousEnvironmentKey: deriveFrom, store: store) else {
                Log.write("切换到新环境 \(environment.key)，没有可用布局")
                return
            }
            Log.write("切换到「\(layout.name)」（\(source.label)）")
            if autoRestore {
                Task { await restore(layout, source: source, in: environment, trigger: "自动") }
            }
        }
    }

    /// 等 macOS 原生恢复完成后，与记录对比并记日志；只观察，不移动任何窗口
    private func checkNativeRestore(of environment: DisplayEnvironment) async {
        try? await Task.sleep(for: .seconds(5))
        guard lastEnvironment.key == environment.key,
              let layout = store.load(environmentKey: environment.key, kind: .pinned)
                ?? store.load(environmentKey: environment.key, kind: .learned) else { return }
        let differences = await Task.detached { Restorer.differences(from: layout, in: environment) }.value
        lastResult = differences.isEmpty
            ? "重新连上「\(layout.name)」，macOS 已原样恢复"
            : "重新连上「\(layout.name)」，与记录相差 \(differences.count) 处，可手动恢复"
        Log.write("\(lastResult!)\n" + differences.map { "  - \($0)" }.joined(separator: "\n"))
    }

    private func name(of environment: DisplayEnvironment) -> String {
        store.load(environmentKey: environment.key, kind: .pinned)?.name
            ?? store.load(environmentKey: environment.key, kind: .learned)?.name
            ?? environment.suggestedName
    }

    private func learnIfStable() {
        guard AX.isTrusted, !isRestoring, let monitor, monitor.isStable(for: Self.learnAfterStable) else { return }
        let environment = Displays.currentEnvironment()
        let changesBefore = monitor.changeCount
        let name = store.load(environmentKey: environment.key, kind: .pinned)?.name
            ?? store.load(environmentKey: environment.key, kind: .learned)?.name
            ?? environment.suggestedName
        Task {
            let layout = await Task.detached { Restorer.snapshot(of: environment, name: name) }.value
            // 采集期间显示器变了或开始恢复，结果可能是被挤乱的中间态，丢弃
            guard !isRestoring, monitor.changeCount == changesBefore, !layout.windows.isEmpty else { return }
            try? store.save(layout, kind: .learned)
        }
    }

    private func restore(_ layout: Layout, source: LayoutSource?, in environment: DisplayEnvironment, trigger: String, keepUndo: Bool = true) async {
        guard !isRestoring else { return }
        isRestoring = true
        let changesBefore = monitor?.changeCount

        if keepUndo {
            undoLayout = await Task.detached { Restorer.snapshot(of: environment, name: "撤销点") }.value
        }
        let report = await Restorer.restore(layout, in: environment) { [weak self] in
            self?.monitor?.changeCount == changesBefore
        }
        let origin = source.map { "（\($0.label)）" } ?? ""
        lastResult = "\(trigger)恢复「\(layout.name)」\(origin)：\(report.summary)"
        Log.write("\(lastResult!)\n\(report.details)")

        isRestoring = false
        if settledWhileRestoring {
            settledWhileRestoring = false
            displaysSettled()
        }
    }

    // MARK: - 对话框

    private func askName(default name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "钉住当前布局"
        alert.informativeText = "钉住的布局优先于自动记录，不会被覆盖。为这组显示器起个名字："
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "钉住")
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
