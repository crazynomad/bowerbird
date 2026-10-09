// 阶段 0b 写操作验证：把某应用的原生全屏窗口移到另一块显示器并重新全屏。
// 运行：swift Probe/fullscreen_move.swift <应用名> <目标显示器 UUID 前缀>
// 例如：swift Probe/fullscreen_move.swift Notes 8789C85C
// 可选第三个参数 <前一个应用>：进入全屏前先激活它，让新 Space 插在它后面
// （实测规律：新全屏 Space 插在目标显示器"当前 Space"的紧后面）
import AppKit
import ApplicationServices

// MARK: - 私有 SkyLight 接口

typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let mainConnection = unsafeBitCast(dlsym(skylight, "SLSMainConnectionID"), to: MainConnectionFn.self)
let copyManagedDisplaySpaces = unsafeBitCast(dlsym(skylight, "SLSCopyManagedDisplaySpaces"), to: CopyManagedDisplaySpacesFn.self)
let copySpacesForWindows = unsafeBitCast(dlsym(skylight, "SLSCopySpacesForWindows"), to: CopySpacesForWindowsFn.self)
// AX 元素 → CGWindowID 的桥接，私有但被 yabai / Hammerspoon 等长期使用
let axGetWindow = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow"), to: GetWindowFn.self)
let cid = mainConnection()

struct SpaceSlot { let display: String; let index: Int; let type: Int }

func spaceMap() -> [UInt64: SpaceSlot] {
    var map: [UInt64: SpaceSlot] = [:]
    for display in copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? [] {
        let displayID = display["Display Identifier"] as? String ?? "?"
        for (i, space) in (display["Spaces"] as? [[String: Any]] ?? []).enumerated() {
            map[space["id64"] as? UInt64 ?? 0] = SpaceSlot(display: displayID, index: i + 1, type: space["type"] as? Int ?? -1)
        }
    }
    return map
}

func printLayout() {
    for display in copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? [] {
        let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
        let types = (display["Spaces"] as? [[String: Any]] ?? []).map {
            (($0["type"] as? Int) == 4 ? "全屏" : "桌面") + (($0["id64"] as? UInt64) == current ? "*" : "")
        }
        print("    \((display["Display Identifier"] as? String ?? "?").prefix(8)): \(types.joined(separator: " | "))")
    }
}

func slot(of wid: CGWindowID) -> SpaceSlot? {
    let ids = copySpacesForWindows(cid, 7, [wid] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    let map = spaceMap()
    return ids.compactMap { map[$0] }.first
}

// MARK: - AX 小工具

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value as? T : nil
}

func isFullScreen(_ win: AXUIElement) -> Bool { attr(win, "AXFullScreen") ?? false }

@discardableResult
func setFullScreen(_ win: AXUIElement, _ on: Bool) -> AXError {
    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, on as CFBoolean)
}

func setFrame(_ win: AXUIElement, _ rect: CGRect) {
    var origin = rect.origin, size = rect.size
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

/// 轮询直到条件满足，返回耗时（秒），超时返回 nil
func waitUntil(timeout: Double = 5, _ condition: () -> Bool) -> Double? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
}

func step(_ name: String, timeout: Double = 5, _ condition: () -> Bool) {
    if let t = waitUntil(timeout: timeout, condition) {
        print("  ✓ \(name)（\(String(format: "%.1f", t))s）")
    } else {
        print("  ✗ \(name) 超时 \(timeout)s"); printLayout(); exit(1)
    }
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { print("用法: fullscreen_move.swift <应用名> <显示器UUID前缀> [前一个应用]"); exit(2) }
let (appName, targetPrefix) = (args[1], args[2].uppercased())
let anchorName = args.count == 4 ? args[3] : nil

func currentSpace(ofDisplay prefix: String) -> UInt64? {
    let displays = copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
    let display = displays.first { ($0["Display Identifier"] as? String)?.hasPrefix(prefix) == true }
    return (display?["Current Space"] as? [String: Any])?["id64"] as? UInt64
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    print("找不到运行中的应用 \(appName)"); exit(1)
}
let windows: [AXUIElement] = attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) ?? []
guard let win = windows.first(where: isFullScreen) ?? windows.first else { print("\(appName) 没有可操作的窗口"); exit(1) }
var wid: CGWindowID = 0
_ = axGetWindow(win, &wid)

guard let targetID = (0..<16).map(CGDirectDisplayID.init).first(where: { id in
    CGDisplayCreateUUIDFromDisplayID(id).map { (CFUUIDCreateString(nil, $0.takeRetainedValue()) as String).hasPrefix(targetPrefix) } ?? false
}) else { print("找不到 UUID 以 \(targetPrefix) 开头的显示器"); exit(1) }
let target = CGDisplayBounds(targetID)  // 全局左上角坐标系，与 AX 一致

print("▶ \(appName) wid=\(wid) 当前位于 \(slot(of: wid).map { "\($0.display.prefix(8))#\($0.index)" } ?? "?")")
print("  初始布局:"); printLayout()

if isFullScreen(win) {
    print("1) 退出全屏  AXError=\(setFullScreen(win, false).rawValue)")
    step("窗口落到普通桌面") { !isFullScreen(win) && slot(of: wid)?.type == 0 }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))  // 等退出动画收尾
} else {
    print("1) 已是普通窗口，跳过退出全屏")
}

print("2) 移到目标显示器 \(targetPrefix)")
setFrame(win, target.insetBy(dx: target.width * 0.1, dy: target.height * 0.1))
step("窗口归属目标显示器") { slot(of: wid)?.display.hasPrefix(targetPrefix) == true }

if let anchorName {
    // AX 只能列出当前 Space 上的窗口，所以锚点应用改用 CGWindowList + SkyLight 定位其全屏 Space
    guard let anchor = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == anchorName }) else {
        print("找不到运行中的应用 \(anchorName)"); exit(1)
    }
    let anchorWids = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == anchor.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    guard let anchorWid = anchorWids.first(where: { slot(of: $0)?.type == 4 && slot(of: $0)?.display.hasPrefix(targetPrefix) == true }) else {
        print("\(anchorName) 在目标显示器上没有全屏窗口"); exit(1)
    }
    let anchorSpace = (copySpacesForWindows(cid, 7, [anchorWid] as CFArray)?.takeRetainedValue() as? [UInt64])?.first
    print("2.5) 激活 \(anchorName)，让目标屏切到它的 Space")
    anchor.activate()
    step("目标屏当前 Space = \(anchorName)") { currentSpace(ofDisplay: targetPrefix) == anchorSpace }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))  // 等切换动画收尾
}

print("  进入全屏前布局（* = 当前 Space）:"); printLayout()
print("3) 重新全屏  AXError=\(setFullScreen(win, true).rawValue)")
step("窗口进入新的全屏 Space", timeout: 8) { isFullScreen(win) && slot(of: wid)?.type == 4 }
RunLoop.current.run(until: Date().addingTimeInterval(0.8))

let final = slot(of: wid)!
let lastIndex = spaceMap().values.filter { $0.display == final.display }.map(\.index).max()!
print("■ 结果：\(final.display.prefix(8))#\(final.index)，该屏共 \(lastIndex) 个 Space → \(final.index == lastIndex ? "✅ 追加在末尾" : "⚠️ 不在末尾")")
print("  最终布局:"); printLayout()
