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
    /// 被显示器变化打断的自动恢复：环境稳定下来仍是同一个时重试
    private var interrupted: (layout: Layout, source: LayoutSource, environment: DisplayEnvironment, attention: AttentionState?)?
    private var lastResult: String?
    private var lastEnvironment = DisplayEnvironment(displays: [])
    private var transitions = TransitionTracker()

    /// 最近的注意力（各屏在看哪一页、焦点在哪），换环境时前台延续它
    private let attentionStore = AttentionStore()
    private var attention: AttentionState?
    private var attentionDebounce: Timer?
    /// 锁屏期间显示器稳定下来，解锁后补处理
    private var settledWhileLocked = false

    /// 显示器身份名册：只有工作屏参与环境识别、记录与恢复
    private let registryStore = DisplayRegistryStore()
    private var registry = DisplayRegistry()
    private var newDisplayPrompt: NewDisplayPrompt?
    private var displaysWindow: DisplaysWindowController?
    private lazy var displaysModel = DisplaysModel { [weak self] uuid, role in self?.setRole(uuid, role) }
    private var loggedMirroring = false

    private let setupStatus = SetupStatus()
    private var setupWindow: SetupWindowController?
    private var statusTimer: Timer?
    /// 恢复进行中：图标在空心/实心小鸟间闪烁，菜单与悬停提示显示当前步骤
    private var restoreProgress: String?
    private var blinkTimer: Timer?

    private var autoRestore: Bool {
        get { UserDefaults.standard.object(forKey: "autoRestore") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRestore") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // 首次启动默认开启开机自动启动，之后尊重用户在菜单里的选择
        if !UserDefaults.standard.bool(forKey: "didSetUpLaunchAtLogin") {
            LaunchAtLogin.setEnabled(true)
            UserDefaults.standard.set(true, forKey: "didSetUpLaunchAtLogin")
        }
        setupStatus.refresh()
        updateIcon()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSetupStatus() }
        }
        if !setupStatus.accessibility || !UserDefaults.standard.bool(forKey: "didShowSetup") {
            showSetup()
            UserDefaults.standard.set(true, forKey: "didShowSetup")
        }

        if !SkyLight.isAvailable { Log.write("⚠️ SkyLight 私有接口不可用，Space 信息将缺失") }
        registry = registryStore.load() ?? DisplayRegistry.bootstrap(from: store.allLayouts())
        registryStore.save(registry)
        registerNewDisplays()
        lastEnvironment = workEnvironment()
        monitor = DisplayMonitor { [weak self] in self?.displaysSettled() }
        attention = attentionStore.load()
        observeUserActivity()
        learnTimer = Timer.scheduledTimer(withTimeInterval: Self.learnInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.learnIfStable() }
        }
        Log.write("启动，当前环境 \(lastEnvironment.key)")
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let environment = workEnvironment()
        let pinned = store.load(environmentKey: environment.key, kind: .pinned)
        let learned = store.load(environmentKey: environment.key, kind: .learned)

        if !setupStatus.accessibility {
            menu.addItem(item("⚠️ 需要辅助功能权限…", #selector(showSetup)))
            menu.addItem(.separator())
        }
        if setupStatus.rearrangesSpaces {
            menu.addItem(item("⚠️ 系统会自动重排 Space，顺序无法保持…", #selector(showSetup)))
            menu.addItem(.separator())
        }
        for uuid in registry.pendingConfirmation where Displays.currentEnvironment().display(uuid: uuid) != nil {
            menu.addItem(item("📽️ 新显示器「\(registry.entries[uuid]?.name ?? uuid)」待确认…", #selector(promptPendingDisplay)))
            menu.addItem(.separator())
        }
        if Displays.isMirroring {
            menu.addItem(info("镜像投屏中，已暂停"))
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
            menu.addItem(info("正在恢复：\(restoreProgress ?? "准备中")…"))
        } else {
            menu.addItem(item("恢复布局", #selector(restoreLayout), enabled: pinned != nil || learned != nil))
            menu.addItem(item("撤销上次恢复", #selector(undoRestore), enabled: undoLayout != nil))
        }
        menu.addItem(item("钉住当前布局…", #selector(pinLayout)))
        menu.addItem(.separator())

        let auto = item("显示器变化时自动恢复", #selector(toggleAutoRestore))
        auto.state = autoRestore ? .on : .off
        menu.addItem(auto)
        let launch = item("开机自动启动", #selector(toggleLaunchAtLogin))
        launch.state = setupStatus.launchAtLogin ? .on : setupStatus.launchAtLoginNeedsApproval ? .mixed : .off
        menu.addItem(launch)
        if let lastResult { menu.addItem(info("上次：\(lastResult)")) }
        menu.addItem(item("查看日志", #selector(openLog)))
        menu.addItem(item("打开布局文件夹", #selector(openLayoutFolder)))
        menu.addItem(item("显示器管理…", #selector(showDisplays)))
        menu.addItem(item("设置与权限…", #selector(showSetup)))
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
        let environment = workEnvironment()
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
        let environment = workEnvironment()
        guard let (layout, source) = LayoutResolver.resolve(for: environment, previousEnvironmentKey: nil, store: store) else { return }
        Task { await restore(layout, source: source, in: environment, trigger: "手动") }
    }

    @objc private func undoRestore() {
        guard let undoLayout else { return }
        self.undoLayout = nil
        Task { await restore(undoLayout, source: nil, in: workEnvironment(), trigger: "撤销", keepUndo: false) }
    }

    @objc private func toggleAutoRestore() { autoRestore.toggle() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func openLayoutFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func toggleLaunchAtLogin() {
        if setupStatus.launchAtLoginNeedsApproval {
            LaunchAtLogin.openSettings()
        } else {
            LaunchAtLogin.setEnabled(!setupStatus.launchAtLogin)
        }
        refreshSetupStatus()
    }

    // MARK: - 显示器身份

    /// Bowerbird 眼中的环境：去掉访客屏和尚未确认的新屏
    private func workEnvironment() -> DisplayEnvironment {
        registry.workEnvironment(Displays.currentEnvironment())
    }

    /// 登记新接入的外接屏：明显是临时投屏的直接记为访客屏，其余先按访客屏处理并询问
    private func registerNewDisplays() {
        let unknown = registry.unknownDisplays(in: Displays.currentEnvironment())
        for display in unknown {
            if let reason = DisplayRegistry.automaticGuestReason(for: display) {
                registry.set(display, role: .guest, confirmed: true, reason: reason)
                Log.write("新显示器「\(display.name)」判定为访客屏（\(reason)），不接管")
            } else {
                registry.set(display, role: .guest, confirmed: false)
                Log.write("新显示器「\(display.name)」\(Int(display.frame.width))×\(Int(display.frame.height))，确认前按访客屏处理")
            }
        }
        if !unknown.isEmpty { registryStore.save(registry) }
        // 上次没回答就退出或重启了的，也要再问
        promptPendingDisplay()
    }

    @objc private func promptPendingDisplay() {
        guard newDisplayPrompt?.window?.isVisible != true,
              let display = registry.pendingConfirmation.lazy.compactMap({ Displays.currentEnvironment().display(uuid: $0) }).first
        else { return }
        newDisplayPrompt = NewDisplayPrompt(display: display) { [weak self] role in
            guard let self else { return }
            self.setRole(display.uuid, role)
            self.newDisplayPrompt = nil
            self.promptPendingDisplay()  // 一次接了多块新屏时逐个询问
        }
        newDisplayPrompt?.present()
    }

    private func setRole(_ uuid: String, _ role: DisplayRole) {
        guard var entry = registry.entries[uuid] else { return }
        entry.role = role
        entry.confirmed = true
        entry.reason = nil
        registry.entries[uuid] = entry
        registryStore.save(registry)
        Log.write("显示器「\(entry.name)」设为\(role == .work ? "工作屏" : "访客屏")")
        reloadDisplaysModel()
        // 身份变了，工作屏环境可能随之变化，按显示器变化处理（例如新确认的工作屏触发整理）
        displaysSettled()
    }

    @objc private func showDisplays() {
        reloadDisplaysModel()
        if displaysWindow == nil { displaysWindow = DisplaysWindowController(model: displaysModel) }
        displaysWindow?.present()
    }

    private func reloadDisplaysModel() {
        displaysModel.reload(registry: registry, connected: Set(Displays.currentEnvironment().displays.map(\.uuid)))
    }

    // MARK: - 授权检测与引导

    @objc private func showSetup() {
        setupStatus.refresh()
        if setupWindow == nil { setupWindow = SetupWindowController(status: setupStatus) }
        setupWindow?.present()
    }

    private func refreshSetupStatus() {
        let wasTrusted = setupStatus.accessibility
        setupStatus.refresh()
        if wasTrusted != setupStatus.accessibility {
            Log.write(setupStatus.accessibility ? "辅助功能已授权" : "⚠️ 辅助功能权限被撤销")
            updateIcon()
        }
    }

    // MARK: - 菜单栏图标

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if isRestoring {
            symbol = blinkPhase ? "bird.fill" : "bird"
            button.toolTip = "Bowerbird 正在恢复：\(restoreProgress ?? "准备中")"
        } else if !setupStatus.accessibility {
            symbol = "exclamationmark.triangle"
            button.toolTip = "Bowerbird 需要辅助功能权限"
        } else {
            symbol = "bird"
            button.toolTip = lastResult.map { "Bowerbird · 上次：\($0)" } ?? "Bowerbird"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Bowerbird")
    }

    private var blinkPhase = false

    private func setRestoring(_ restoring: Bool) {
        isRestoring = restoring
        blinkTimer?.invalidate()
        blinkTimer = nil
        if restoring {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkPhase.toggle()
                    self.updateIcon()
                }
            }
        } else {
            restoreProgress = nil
            blinkPhase = false
        }
        updateIcon()
    }

    // MARK: - 自动恢复与自动记录

    private func displaysSettled() {
        guard !isRestoring else {
            settledWhileRestoring = true
            return
        }
        // 镜像投屏中：多半在演示，整体暂停
        guard !Displays.isMirroring else {
            if !loggedMirroring { Log.write("检测到镜像投屏，暂停处理") }
            loggedMirroring = true
            return
        }
        loggedMirroring = false
        registerNewDisplays()
        let environment = workEnvironment()
        if let pending = interrupted, pending.environment.key != environment.key { interrupted = nil }
        guard environment.key != lastEnvironment.key else {
            retryInterruptedRestore(in: environment)
            return
        }
        // 唤醒时若仍在锁屏，读不到任何窗口；等解锁后再判断，避免白白"用掉"这次切换
        guard !Session.isLocked else {
            if !settledWhileLocked { Log.write("显示器变为 \(describe(environment))，屏幕已锁定，解锁后再处理") }
            settledWhileLocked = true
            return
        }
        settledWhileLocked = false
        let transition = transitions.transition(from: lastEnvironment, to: environment)
        Log.write("显示器：\(describe(lastEnvironment)) → \(describe(environment))")
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
            // 前台延续最近的注意力；它若就来自这个环境（例如断开后在原地重连），则以布局为准
            let carried = attention.flatMap { $0.environmentKey != environment.key ? $0 : nil }
            Log.write("切换到「\(layout.name)」（\(source.label)）" + (carried.map { "，前台延续 \(describeAttention($0))" } ?? ""))
            if autoRestore {
                Task { await restore(layout, source: source, in: environment, trigger: "自动", attention: carried) }
            }
        }
    }

    /// 自动恢复被途中的显示器变化打断（例如解锁瞬间外接屏还在陆续上线），环境稳定后仍是同一个就重来一次
    private func retryInterruptedRestore(in environment: DisplayEnvironment) {
        guard let pending = interrupted, pending.environment.key == environment.key, !Session.isLocked else { return }
        interrupted = nil
        Log.write("上次自动恢复被打断，显示器已稳定，重试「\(pending.layout.name)」")
        Task { await restore(pending.layout, source: pending.source, in: environment, trigger: "自动", attention: pending.attention) }
    }

    // MARK: - 注意力

    /// 只在用户操作（切换应用、切换 Space）时观察，不定时轮询：
    /// 显示器变化后 macOS 自己挪出来的前台不是用户意图，不能当成注意力
    private func observeUserActivity() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAttentionObservation() }
            }
        }
        // 解锁后补处理锁屏期间到来的显示器变化
        let unlock: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settledWhileLocked else { return }
                // 解锁瞬间外接屏往往还在陆续上线：交给稳定后的回调处理，否则恢复刚开始就会被打断
                guard self.monitor?.isSettling != true else {
                    Log.write("屏幕已解锁，等显示器稳定后再处理")
                    return
                }
                Log.write("屏幕已解锁，补处理显示器变化")
                self.displaysSettled()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: unlock)
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: unlock)
    }

    /// 切换 Space 有动画，稍等再看；连续切换只观察最后一次
    private func scheduleAttentionObservation() {
        attentionDebounce?.invalidate()
        attentionDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeAttention() }
        }
    }

    private func observeAttention() {
        guard AX.isTrusted, !isRestoring, !Session.isLocked, !Displays.isMirroring, monitor?.isStable(for: 10) == true else { return }
        let observed = AttentionObserver.observe(in: workEnvironment())
        guard attention.map({ !$0.sameContent(as: observed) }) ?? true else { return }
        attention = observed
        attentionStore.save(observed)
    }

    private func describe(_ environment: DisplayEnvironment) -> String {
        environment.displays.isEmpty ? "（无）" : environment.displays.map { $0.isBuiltin ? "内建屏" : $0.name }.joined(separator: " + ")
    }

    private func describeAttention(_ state: AttentionState) -> String {
        let pages = state.pages.map { page in
            let display = state.displays.first { $0.uuid == page.displayUUID }.map { $0.isBuiltin ? "内建屏" : $0.name } ?? "?"
            return "\(display)：\(page.fullScreen.map(appName(of:)) ?? "桌面")"
        }
        return pages.joined(separator: "，") + (state.focused.map { "；焦点 \(appName(of: $0))" } ?? "")
    }

    private func appName(of ref: WindowIdentity) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: ref.bundleID).first?.localizedName ?? ref.bundleID
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
        guard AX.isTrusted, !isRestoring, !Session.isLocked, !Displays.isMirroring, let monitor, monitor.isStable(for: Self.learnAfterStable) else { return }
        let environment = workEnvironment()
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

    private func restore(_ layout: Layout, source: LayoutSource?, in environment: DisplayEnvironment, trigger: String,
                         keepUndo: Bool = true, attention: AttentionState? = nil) async {
        guard !isRestoring else { return }
        setRestoring(true)
        let changesBefore = monitor?.changeCount

        if keepUndo {
            undoLayout = await Task.detached { Restorer.snapshot(of: environment, name: "撤销点") }.value
        }
        let report = await Restorer.restore(layout, in: environment, attention: attention) { [weak self] in
            self?.monitor?.changeCount == changesBefore
        } progress: { [weak self] step in
            self?.restoreProgress = step
            self?.updateIcon()
        }
        let origin = source.map { "（\($0.label)）" } ?? ""
        lastResult = "\(trigger)恢复「\(layout.name)」\(origin)：\(report.summary)"
        Log.write("\(lastResult!)\n\(report.details)")
        if report.wasAborted, trigger == "自动", let source {
            interrupted = (layout, source, environment, attention)
        }

        setRestoring(false)
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
