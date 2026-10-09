// 阶段 0 摸底工具：只读，打印显示器、Spaces 顺序、以及每个窗口所在的 Space。
// 运行：swift Probe/probe.swift
import AppKit
import CoreGraphics

// MARK: - 私有 SkyLight 接口（通过 dlsym 加载，找不到时给出明确提示而不是崩溃）

typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

func load<T>(_ names: [String], as _: T.Type) -> T? {
    for name in names {
        if let sym = dlsym(skylight, name) { return unsafeBitCast(sym, to: T.self) }
    }
    print("⚠️  私有接口不可用: \(names.joined(separator: " / "))")
    return nil
}

let mainConnection = load(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFn.self)
let copyManagedDisplaySpaces = load(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyManagedDisplaySpacesFn.self)
let copySpacesForWindows = load(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFn.self)

// MARK: - 显示器

print("== 显示器 ==")
for screen in NSScreen.screens {
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "?"
    let builtin = CGDisplayIsBuiltin(id) != 0 ? "内建" : "外接"
    print("\(screen.localizedName) [\(builtin)] id=\(id) uuid=\(uuid) frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
}

// MARK: - Spaces 顺序

let spaceTypeNames = [0: "普通桌面", 4: "原生全屏"]

guard let cid = mainConnection?(), let displays = copyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else {
    print("❌ 无法读取 Spaces，私有接口在此系统上失效")
    exit(1)
}

print("\n== Spaces（按顺序）==")
var spaceLabel: [UInt64: String] = [:]
for display in displays {
    let displayID = display["Display Identifier"] as? String ?? "?"
    let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
    print("显示器 \(displayID)")
    for (index, space) in (display["Spaces"] as? [[String: Any]] ?? []).enumerated() {
        let id = space["id64"] as? UInt64 ?? 0
        let type = space["type"] as? Int ?? -1
        let marker = id == current ? " ← 当前" : ""
        let label = "\(index + 1). \(spaceTypeNames[type] ?? "type \(type)") id=\(id)"
        spaceLabel[id] = "\(displayID.prefix(8))…#\(index + 1)"
        print("  \(label)\(marker)")
    }
}

// MARK: - 窗口 → Space

print("\n== 窗口（含其它 Space 上的）==")
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard (window[kCGWindowLayer as String] as? Int) == 0,
          let wid = window[kCGWindowNumber as String] as? Int,
          let owner = window[kCGWindowOwnerName as String] as? String,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          (bounds["Width"] ?? 0) > 100, (bounds["Height"] ?? 0) > 100 else { continue }
    // mask 7 = 所有 Space（当前 + 其它 + 全屏）
    let spaces = copySpacesForWindows?(cid, 7, [wid] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    guard !spaces.isEmpty else { continue }  // 不属于任何 Space 的多为隐藏/辅助窗口
    let title = window[kCGWindowName as String] as? String ?? "（无标题，需屏幕录制权限）"
    let where_ = spaces.map { spaceLabel[$0] ?? "\($0)" }.joined(separator: ",")
    print("\(owner) wid=\(wid) space=\(where_) bounds=\(Int(bounds["X"]!)),\(Int(bounds["Y"]!)) \(Int(bounds["Width"]!))x\(Int(bounds["Height"]!)) 「\(title)」")
}
