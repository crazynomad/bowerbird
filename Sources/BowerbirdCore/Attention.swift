import AppKit

/// 指向某个窗口的引用，用于在另一个环境的布局里找到"同一个窗口"
public struct WindowIdentity: Codable, Equatable, Sendable {
    public var bundleID: String
    public var title: String
    public var windowID: UInt32?

    public init(bundleID: String, title: String, windowID: UInt32?) {
        (self.bundleID, self.title, self.windowID) = (bundleID, title, windowID)
    }
}

/// 用户"正在看哪"：每块屏当前显示的页和键盘焦点。
///
/// 与布局分开：窗口住在哪是每个环境各一套的空间记忆，正在看哪则跟着人走。
/// 从家里回到公司时，窗口按公司的布局摆放，前台和焦点却应延续在家最后的状态。
public struct AttentionState: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public var displayUUID: String
        /// 该屏当前全屏页上的窗口；nil 表示停在普通桌面
        public var fullScreen: WindowIdentity?

        public init(displayUUID: String, fullScreen: WindowIdentity?) {
            (self.displayUUID, self.fullScreen) = (displayUUID, fullScreen)
        }
    }

    public var environmentKey: String
    /// 观察时的显示器，用于把"停在普通桌面"映射到新环境的屏
    public var displays: [DisplayInfo]
    public var pages: [Page]
    public var focused: WindowIdentity?
    /// 焦点窗口所在的显示器，冲突时它那一页优先
    public var focusedDisplayUUID: String?
    public var observedAt: Date

    public init(environmentKey: String, displays: [DisplayInfo], pages: [Page], focused: WindowIdentity?,
                focusedDisplayUUID: String?, observedAt: Date) {
        self.environmentKey = environmentKey
        self.displays = displays
        self.pages = pages
        self.focused = focused
        self.focusedDisplayUUID = focusedDisplayUUID
        self.observedAt = observedAt
    }

    /// 忽略观察时间比较内容，避免没变化时反复写盘
    public func sameContent(as other: AttentionState) -> Bool {
        environmentKey == other.environmentKey && pages == other.pages
            && focused == other.focused && focusedDisplayUUID == other.focusedDisplayUUID
    }
}

/// 轻量观察当前注意力：只看各屏当前 Space 和焦点窗口，不做完整的窗口采集
public enum AttentionObserver {
    public static func observe(in environment: DisplayEnvironment) -> AttentionState {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

        var pages: [AttentionState.Page] = []
        for display in SkyLight.displaySpaces() where environment.display(uuid: display.displayUUID) != nil {
            guard let current = display.currentSpaceID,
                  let space = display.spaces.first(where: { $0.id == current }) else { continue }
            var ref: WindowIdentity?
            // 全屏页上可能还有透明的辅助窗口（例如 Claude 顶部 32 像素高的隐形工具栏），取不透明且面积最大的那个
            if space.kind == .fullScreen,
               let window = onScreen
                   .filter({ info in
                       (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
                           && (info[kCGWindowNumber as String] as? CGWindowID).map { SkyLight.spaceIDs(forWindow: $0).contains(current) } ?? false
                   })
                   .max(by: { area($0) < area($1) }),
               let wid = window[kCGWindowNumber as String] as? CGWindowID,
               let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                ref = windowRef(pid: pid, windowID: wid)
            }
            pages.append(.init(displayUUID: display.displayUUID, fullScreen: ref))
        }

        var focused: WindowIdentity?
        var focusedDisplay: String?
        if let app = NSWorkspace.shared.frontmostApplication,
           let element: AXUIElement = AX.value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
           let wid = AXBridge.windowID(of: element) {
            focused = WindowIdentity(bundleID: app.bundleIdentifier ?? app.localizedName ?? "", title: AX.title(of: element), windowID: wid)
            focusedDisplay = SkyLight.location(ofWindow: wid)?.displayUUID
        }
        return AttentionState(environmentKey: environment.key, displays: environment.displays, pages: pages,
                              focused: focused, focusedDisplayUUID: focusedDisplay, observedAt: Date())
    }

    private static func area(_ info: [String: Any]) -> CGFloat {
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }

    private static func windowRef(pid: pid_t, windowID: CGWindowID) -> WindowIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let title = AXBridge.windows(pid: pid, expected: [windowID])[windowID].map(AX.title(of:)) ?? ""
        return WindowIdentity(bundleID: app.bundleIdentifier ?? app.localizedName ?? "", title: title, windowID: windowID)
    }
}

/// 恢复后每块屏该停在哪一页
public enum ForegroundChoice: Equatable, Sendable {
    /// 显示某条记录对应的全屏窗口
    case fullScreen(record: Int)
    /// 停在普通桌面；`via` 为借来切换的普通窗口记录（普通桌面本身无法激活）
    case desktop(via: Int?)
}

public struct ForegroundPlan: Equatable, Sendable {
    public var pages: [String: ForegroundChoice]
    /// 恢复结束后获得键盘焦点的记录
    public var focus: Int?
}

/// 决定恢复后各屏前台页与焦点（纯函数）：
/// 1. 以目标布局自己记录的前台为底（上次在这个环境时的样子）
/// 2. 叠加最近的注意力：按应用找到它在目标布局里住在哪块屏，让那块屏显示它；
///    停在普通桌面的屏按显示器对应规则映射。焦点所在页优先，其次内建屏、再按分辨率
/// 3. 焦点用注意力里的焦点窗口
public enum ForegroundPlanner {
    public static func plan(layout: Layout, environment: DisplayEnvironment, attention: AttentionState?) -> ForegroundPlan {
        let records = layout.windows
        var pages: [String: ForegroundChoice] = [:]

        func normalWindow(on display: String, preferring preferred: Int? = nil) -> Int? {
            if let preferred, records[preferred].displayUUID == display, !records[preferred].isFullScreen { return preferred }
            let normal = records.indices.filter { records[$0].displayUUID == display && !records[$0].isFullScreen }
            return normal.first { records[$0].isFocused == true } ?? normal.first
        }

        for display in environment.displays {
            if let index = records.firstIndex(where: { $0.isForeground == true && $0.displayUUID == display.uuid }) {
                pages[display.uuid] = .fullScreen(record: index)
            } else if layout.desktopForeground?.contains(display.uuid) == true {
                pages[display.uuid] = .desktop(via: normalWindow(on: display.uuid))
            }
        }
        var focus = records.firstIndex { $0.isFocused == true }

        guard let attention else { return ForegroundPlan(pages: pages, focus: focus) }

        let focusedRecord = attention.focused.flatMap { match($0, in: records) }
        let mapping = Dictionary(
            LayoutMapper.displayMapping(from: attention.displays, to: environment.displays).map { ($0.source.uuid, $0.target.uuid) },
            uniquingKeysWith: { first, _ in first })

        var claimed = Set<String>()
        for page in ordered(attention) {
            if let ref = page.fullScreen {
                guard let index = match(ref, in: records) else { continue }
                let display = records[index].displayUUID
                guard environment.display(uuid: display) != nil, !claimed.contains(display) else { continue }
                // 在目标环境里它若不是全屏，就停在它所在的普通桌面
                pages[display] = records[index].isFullScreen ? .fullScreen(record: index) : .desktop(via: index)
                claimed.insert(display)
            } else {
                guard let display = mapping[page.displayUUID], !claimed.contains(display) else { continue }
                pages[display] = .desktop(via: normalWindow(on: display, preferring: focusedRecord))
                claimed.insert(display)
            }
        }
        if let focusedRecord { focus = focusedRecord }
        return ForegroundPlan(pages: pages, focus: focus)
    }

    /// 焦点所在页优先，其次内建屏，再按分辨率从高到低
    private static func ordered(_ attention: AttentionState) -> [AttentionState.Page] {
        func rank(_ page: AttentionState.Page) -> (Int, Int, Double) {
            let display = attention.displays.first { $0.uuid == page.displayUUID }
            return (page.displayUUID == attention.focusedDisplayUUID ? 0 : 1,
                    display?.isBuiltin == true ? 0 : 1,
                    -(display.map { $0.frame.width * $0.frame.height } ?? 0))
        }
        return attention.pages.sorted { rank($0) < rank($1) }
    }

    /// 同一窗口 ID（同一次登录内）→ 同应用同标题 → 同应用唯一窗口
    static func match(_ ref: WindowIdentity, in records: [WindowRecord]) -> Int? {
        let sameApp = records.indices.filter { records[$0].bundleID == ref.bundleID }
        if let id = ref.windowID, let index = sameApp.first(where: { records[$0].windowID == id }) { return index }
        if let index = sameApp.first(where: { records[$0].title == ref.title }) { return index }
        return sameApp.count == 1 ? sameApp[0] : nil
    }
}

/// 注意力状态持久化在 ~/Library/Application Support/Bowerbird/attention.json，重启后仍可延续
public struct AttentionStore: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bowerbird/attention.json")) {
        self.url = url
    }

    public func load() -> AttentionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AttentionState.self, from: data)
    }

    public func save(_ state: AttentionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: url, options: .atomic)
    }
}

/// 屏幕锁定或会话不在前台时读不到任何窗口，此时不应恢复、记录或观察
public enum Session {
    public static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (session["kCGSSessionOnConsoleKey"] as? Bool) == false
    }
}
