import AppKit

public struct RestoreReport: Sendable {
    public var moved: [String] = []
    public var fullScreenRestored: [String] = []
    /// 恢复后各显示器切到的前台页
    public var foreground: [String] = []
    public var alreadyInPlace: [String] = []
    public var notFound: [String] = []
    public var failed: [String] = []
    /// 能恢复但与目标有出入的地方（例如全屏无法排到普通桌面之前）
    public var notes: [String] = []

    public init() {}

    public var summary: String {
        var parts = ["移动 \(moved.count)", "全屏 \(fullScreenRestored.count)", "原位 \(alreadyInPlace.count)"]
        if !notFound.isEmpty { parts.append("未找到 \(notFound.count)") }
        if !failed.isEmpty { parts.append("失败 \(failed.count)") }
        return parts.joined(separator: "，")
    }

    public var details: String {
        [("移动", moved), ("全屏", fullScreenRestored), ("前台", foreground), ("未找到", notFound), ("失败", failed), ("注意", notes)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0)：\n" + $0.1.map { "  - \($0)" }.joined(separator: "\n") }
            .joined(separator: "\n")
    }
}

@MainActor
public enum Restorer {
    /// 不触碰 UI，可在后台线程执行（用于定期自动记录）
    public nonisolated static func snapshot(of environment: DisplayEnvironment, name: String) -> Layout {
        let records = WindowCatalog.capture(in: environment)
            .sorted { $0.windowID < $1.windowID }
            .compactMap { window in environment.display(uuid: window.displayUUID).map { WindowRecord(window, display: $0) } }
        let desktopForeground = SkyLight.displaySpaces()
            .filter { display in
                environment.display(uuid: display.displayUUID) != nil
                    && display.spaces.first { $0.id == display.currentSpaceID }?.kind == .desktop
            }
            .map(\.displayUUID)
        return Layout(environmentKey: environment.key, name: name, savedAt: Date(), displays: environment.displays,
                      windows: records, desktopForeground: desktopForeground)
    }

    /// 当前窗口与布局的差异，只读不移动。用于检查 macOS 原生恢复的效果。
    /// 已关闭的窗口不算差异；Space 顺序用与恢复相同的规划判断，规划认为无需再动的（例如做不到的
    /// "全屏排在普通桌面之前"）不算差异，避免报出恢复也消除不了的"差异"。
    public nonisolated static func differences(from layout: Layout, in environment: DisplayEnvironment) -> [String] {
        let live = WindowCatalog.capture(in: environment)
        let pairs = pairUp(layout, live: live, in: environment).pairs
        let reentering = Set(plans(for: layout, pairs: pairs, live: live, in: environment).flatMap { $0.1.steps.map(\.windowID) })
        func name(_ uuid: String) -> String { environment.display(uuid: uuid)?.name ?? String(uuid.prefix(8)) }

        return pairs.compactMap { pair in
            let (record, window) = (pair.record, pair.window)
            if window.displayUUID != record.displayUUID {
                return "\(window.label)：在 \(name(window.displayUUID))，应在 \(name(record.displayUUID))"
            }
            if window.isFullScreen != record.isFullScreen {
                return "\(window.label)：\(record.isFullScreen ? "应为全屏" : "不应全屏")"
            }
            if record.isFullScreen, reentering.contains(window.windowID) {
                return "\(window.label)：Space 顺序与记录不符（当前第 \(window.space?.index ?? 0) 个）"
            }
            if !record.isFullScreen, let display = environment.display(uuid: record.displayUUID),
               !FrameMapper.isClose(window.frame, FrameMapper.place(record.frame, on: display.frame.cgRect)) {
                return "\(window.label)：位置或尺寸不同"
            }
            return nil
        }
    }

    private struct Pair {
        let recordIndex: Int
        let record: WindowRecord
        let window: LiveWindow
    }

    /// 配对保存的记录与当前窗口；同时返回找不到窗口的记录和目标显示器未接入的记录
    private nonisolated static func pairUp(_ layout: Layout, live: [LiveWindow], in environment: DisplayEnvironment)
        -> (pairs: [Pair], notFound: [String], missingDisplay: [String]) {
        let matches = WindowMatcher.match(saved: layout.windows.map(\.matchCandidate), live: live.map(\.matchCandidate))
        var result: (pairs: [Pair], notFound: [String], missingDisplay: [String]) = ([], [], [])
        for (index, record) in layout.windows.enumerated() {
            guard let liveIndex = matches[index] else { result.notFound.append(label(record)); continue }
            guard environment.display(uuid: record.displayUUID) != nil else { result.missingDisplay.append(label(record)); continue }
            result.pairs.append(Pair(recordIndex: index, record: record, window: live[liveIndex]))
        }
        return result
    }

    private nonisolated static func plans(for layout: Layout, pairs: [Pair], live: [LiveWindow], in environment: DisplayEnvironment)
        -> [(DisplayInfo, SpacePlan)] {
        environment.displays.map { display in
            (display, SpacePlanner.plan(desired: desiredSlots(on: display, layout: layout, pairs: pairs),
                                        current: currentSlots(on: display, live: live)))
        }
    }

    /// 恢复流程：配对 → 规划各屏全屏顺序 → 退出需要重排的全屏 → 摆放普通窗口 → 按顺序重新进入全屏。
    /// 每一步前检查 `shouldContinue`：显示器在恢复途中又变化时立即中止，避免按过时的环境挪窗口。
    /// `progress` 在每一步开始时报告正在做什么，供界面展示。
    public static func restore(_ layout: Layout, in environment: DisplayEnvironment,
                               shouldContinue: () -> Bool = { true },
                               progress: (String) -> Void = { _ in }) async -> RestoreReport {
        var report = RestoreReport()
        func aborted() -> Bool {
            if shouldContinue() { return false }
            report.notes.append("显示器配置在恢复途中发生变化，已中止剩余步骤")
            return true
        }
        let live = WindowCatalog.capture(in: environment)
        let liveByID = Dictionary(live.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let (pairs, notFound, missingDisplay) = pairUp(layout, live: live, in: environment)
        report.notFound = notFound
        report.failed = missingDisplay.map { "\($0)：目标显示器未接入" }

        let plans = plans(for: layout, pairs: pairs, live: live, in: environment)
        let reentering = Set(plans.flatMap { $0.1.steps.map(\.windowID) })

        for pair in pairs where pair.window.isFullScreen && (reentering.contains(pair.window.windowID) || !pair.record.isFullScreen) {
            if aborted() { return report }
            progress("退出全屏：\(pair.window.appName)")
            if !(await exitFullScreen(pair.window)) {
                report.failed.append("\(pair.window.label)：退出全屏超时")
            }
        }

        if pairs.contains(where: { !$0.record.isFullScreen }) { progress("摆放普通窗口") }
        for pair in pairs where !pair.record.isFullScreen {
            if aborted() { return report }
            await restoreFrame(pair, in: environment, report: &report)
        }

        for (display, plan) in plans {
            if plan.demotedBeforeDesktop {
                report.notes.append("\(display.name)：全屏无法排在普通桌面之前，已依次排在其后")
            }
            for step in plan.steps {
                if aborted() { return report }
                guard let window = liveByID[step.windowID] else { continue }
                progress("全屏：\(window.appName) → \(display.name)")
                let anchor: LiveWindow? = if case .window(let id) = step.after { liveByID[id] } else { nil }
                if let location = await enterFullScreen(window, on: display, after: anchor) {
                    report.fullScreenRestored.append("\(window.label) → \(display.name) 第 \(location.index) 个 Space")
                } else {
                    report.failed.append("\(window.label)：未能在 \(display.name) 上进入全屏")
                }
            }
        }

        for pair in pairs where pair.record.isFullScreen && pair.window.isFullScreen && !reentering.contains(pair.window.windowID) {
            report.alreadyInPlace.append(pair.window.label)
        }
        if aborted() { return report }
        progress("切换各屏前台页")
        await restoreForeground(layout, pairs: pairs, in: environment, report: &report)
        return report
    }

    // MARK: - 前台页与焦点

    /// 把每块屏切回保存时显示的那一页，最后把键盘焦点还给保存时最前面的窗口
    private static func restoreForeground(_ layout: Layout, pairs: [Pair], in environment: DisplayEnvironment, report: inout RestoreReport) async {
        for display in environment.displays {
            let target: LiveWindow?
            if let pair = pairs.first(where: { $0.record.isForeground == true && $0.record.displayUUID == display.uuid }) {
                target = pair.window
            } else if layout.desktopForeground?.contains(display.uuid) == true {
                // 普通桌面本身无法激活，借桌面上的一个窗口切过去，优先保存时有焦点的那个
                target = pairs
                    .filter { !$0.record.isFullScreen && $0.record.displayUUID == display.uuid }
                    .min { ($0.record.isFocused == true ? 0 : 1) < ($1.record.isFocused == true ? 0 : 1) }?
                    .window
                if target == nil { report.notes.append("\(display.name)：普通桌面上没有窗口，无法切回桌面") }
            } else {
                continue  // 旧布局没有前台信息
            }
            guard let target, let location = SkyLight.location(ofWindow: target.windowID) else { continue }
            let page = location.kind == .fullScreen ? target.label : "普通桌面"
            report.foreground.append("\(display.name) → \(page)")
            if SkyLight.spaces(onDisplay: location.displayUUID)?.currentSpaceID != location.id {
                await focus(target)
            }
        }
        // 只在焦点窗口就在其显示器的当前页上时才激活，绝不为了焦点再切换页面
        if let focused = pairs.first(where: { $0.record.isFocused == true })?.window,
           let location = SkyLight.location(ofWindow: focused.windowID),
           SkyLight.spaces(onDisplay: location.displayUUID)?.currentSpaceID == location.id {
            await focus(focused)
        }
    }

    // MARK: - 规划输入

    private nonisolated static func desiredSlots(on display: DisplayInfo, layout: Layout, pairs: [Pair]) -> [SpaceSlot] {
        let pairByRecord = Dictionary(uniqueKeysWithValues: pairs.map { ($0.recordIndex, $0) })
        return layout.spaceSequence(on: display.uuid).compactMap { item in
            guard let index = item else { return .desktop }
            guard let pair = pairByRecord[index] else { return nil }  // 应用没在运行
            return .window(pair.window.windowID)
        }
    }

    private nonisolated static func currentSlots(on display: DisplayInfo, live: [LiveWindow]) -> [SpaceSlot] {
        guard let spaces = SkyLight.spaces(onDisplay: display.uuid)?.spaces else { return [] }
        var slots: [SpaceSlot] = []
        for space in spaces {
            switch space.kind {
            case .desktop where !slots.contains(.desktop):
                slots.append(.desktop)
            case .fullScreen:
                if let window = live.first(where: { $0.isFullScreen && $0.space?.id == space.id }) {
                    slots.append(.window(window.windowID))
                }
            default:
                break
            }
        }
        return slots
    }

    // MARK: - 普通窗口

    private static func restoreFrame(_ pair: Pair, in environment: DisplayEnvironment, report: inout RestoreReport) async {
        let window = pair.window
        guard let display = environment.display(uuid: pair.record.displayUUID) else { return }
        let target = FrameMapper.place(pair.record.frame, on: display.frame.cgRect)
        let current = AX.frame(of: window.element) ?? window.frame
        let currentDisplay = SkyLight.location(ofWindow: window.windowID)?.displayUUID ?? window.displayUUID
        if currentDisplay == display.uuid && FrameMapper.isClose(current, target) {
            report.alreadyInPlace.append(window.label)
            return
        }
        if await apply(target, to: window.element) {
            report.moved.append(window.label)
        } else {
            let actual = AX.frame(of: window.element).map { "\(Rect($0))" } ?? "未知"
            report.failed.append("\(window.label)：目标 \(Rect(target))，实际 \(actual)")
        }
    }

    /// 设置后回读校验，不到位再试一次（有的应用会在下一帧才响应尺寸变化）
    private static func apply(_ frame: CGRect, to element: AXUIElement) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { await pause(0.15) }
            AX.setFrame(element, frame)
            if let actual = AX.frame(of: element), FrameMapper.isClose(actual, frame) { return true }
        }
        return false
    }

    // MARK: - 原生全屏（流程见 IDEAS.md 阶段 0b）

    private static func exitFullScreen(_ window: LiveWindow) async -> Bool {
        await focus(window)
        AX.setFullScreen(window.element, false)
        let done = await waitUntil(5) {
            !AX.isFullScreen(window.element) && SkyLight.location(ofWindow: window.windowID)?.kind == .desktop
        }
        await pause(0.8)  // 等退出动画收尾，否则紧接着的移动可能被系统覆盖
        return done
    }

    /// 移到目标屏 → 让目标屏切到锚点（nil 表示普通桌面）→ 进入全屏。新 Space 会插在锚点紧后面
    private static func enterFullScreen(_ window: LiveWindow, on display: DisplayInfo, after anchor: LiveWindow?) async -> SpaceLocation? {
        let bounds = display.frame.cgRect
        AX.setFrame(window.element, bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1))
        _ = await waitUntil(2) { SkyLight.location(ofWindow: window.windowID)?.displayUUID == display.uuid }

        // 锚点是普通桌面时，聚焦窗口自身即可让目标屏切到它所在的桌面
        await focus(anchor ?? window)
        AX.setFullScreen(window.element, true)
        let entered = await waitUntil(8) {
            AX.isFullScreen(window.element) && SkyLight.location(ofWindow: window.windowID)?.kind == .fullScreen
        }
        await pause(0.8)
        guard entered, let location = SkyLight.location(ofWindow: window.windowID), location.displayUUID == display.uuid else { return nil }
        return location
    }

    /// 激活窗口并等待其所在显示器切到它的 Space
    private static func focus(_ window: LiveWindow) async {
        AX.raise(window.element)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        guard let location = SkyLight.location(ofWindow: window.windowID) else { return }
        let switched = await waitUntil(2) { SkyLight.spaces(onDisplay: location.displayUUID)?.currentSpaceID == location.id }
        if switched { await pause(0.5) }  // 等切换动画收尾
    }

    // MARK: - 工具

    private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.1)
        }
        return condition()
    }

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private nonisolated static func label(_ record: WindowRecord) -> String {
        record.title.isEmpty ? record.appName : "\(record.appName)「\(record.title)」"
    }
}
