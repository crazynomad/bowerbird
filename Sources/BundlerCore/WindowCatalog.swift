import AppKit

/// 当前存在的一个可控窗口
public struct LiveWindow {
    public let element: AXUIElement
    public let windowID: CGWindowID
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let title: String
    /// 全局坐标
    public let frame: CGRect
    public let isFullScreen: Bool
    public let displayUUID: String
    public let space: SpaceLocation?

    public var label: String { title.isEmpty ? appName : "\(appName)「\(title)」" }
    public var matchCandidate: MatchCandidate { MatchCandidate(bundleID: bundleID, title: title, windowID: windowID) }
}

@MainActor
public enum WindowCatalog {
    /// 枚举所有 Space 上普通应用的可见窗口（跳过最小化和隐藏辅助窗口）
    public static func capture(in environment: DisplayEnvironment) -> [LiveWindow] {
        let spaces = SkyLight.spaceLocations()
        let realWindows = realWindowIDsByPID()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .flatMap { app -> [LiveWindow] in
                guard let expected = realWindows[app.processIdentifier] else { return [] }
                return AXBridge.windows(pid: app.processIdentifier, expected: expected).compactMap { wid, element in
                    guard !AX.isMinimized(element), let frame = AX.frame(of: element) else { return nil }
                    let space = SkyLight.spaceIDs(forWindow: wid).lazy.compactMap { spaces[$0] }.first
                    guard let displayUUID = displayUUID(space: space, frame: frame, environment: environment) else { return nil }
                    return LiveWindow(
                        element: element,
                        windowID: wid,
                        pid: app.processIdentifier,
                        bundleID: app.bundleIdentifier ?? app.localizedName ?? "",
                        appName: app.localizedName ?? "",
                        title: AX.title(of: element),
                        frame: frame,
                        isFullScreen: AX.isFullScreen(element),
                        displayUUID: displayUUID,
                        space: space
                    )
                }
            }
    }

    /// 远程令牌枚举会带出隐藏的辅助窗口；真实窗口必须在第 0 层、尺寸像样且属于某个 Space
    private static func realWindowIDsByPID() -> [pid_t: Set<CGWindowID>] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [pid_t: Set<CGWindowID>] = [:]
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let wid = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50,
                  !SkyLight.spaceIDs(forWindow: wid).isEmpty else { continue }
            result[pid, default: []].insert(wid)
        }
        return result
    }

    private static func displayUUID(space: SpaceLocation?, frame: CGRect, environment: DisplayEnvironment) -> String? {
        if let uuid = space?.displayUUID, environment.display(uuid: uuid) != nil { return uuid }
        // "显示器使用独立空间"关闭时 SkyLight 只报告 "Main"，退回按窗口中心判断
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return environment.displays.first { $0.frame.cgRect.contains(center) }?.uuid
    }
}

extension WindowRecord {
    public init(_ window: LiveWindow, display: DisplayInfo) {
        self.init(
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            displayUUID: display.uuid,
            frame: FrameMapper.relative(window.frame, to: display.frame.cgRect),
            isFullScreen: window.isFullScreen,
            spaceIndex: window.space?.index ?? 0,
            windowID: window.windowID
        )
    }
}
