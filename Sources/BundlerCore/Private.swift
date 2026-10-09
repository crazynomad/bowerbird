// 所有私有接口集中在这里。macOS 升级后若失效，只需修改本文件。
// 已在 macOS 26.6.2 上验证（见 IDEAS.md 阶段 0 / 0b）。
import AppKit
import ApplicationServices

public enum SpaceKind: String, Codable, Sendable {
    case desktop, fullScreen, other
}

public struct SpaceInfo: Equatable, Sendable {
    public let id: UInt64
    public let kind: SpaceKind
}

public struct DisplaySpaces: Equatable, Sendable {
    public let displayUUID: String
    public let currentSpaceID: UInt64?
    /// 按 Mission Control 中从左到右的顺序
    public let spaces: [SpaceInfo]
}

/// 某个 Space 在全局中的位置
public struct SpaceLocation: Equatable, Sendable {
    public let id: UInt64
    public let displayUUID: String
    /// 从 1 开始
    public let index: Int
    public let kind: SpaceKind
}

public enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection: MainConnectionFn? = symbol(handle, "SLSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = symbol(handle, "SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindowsFn? = symbol(handle, "SLSCopySpacesForWindows")

    public static var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }

    public static func displaySpaces() -> [DisplaySpaces] {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let raw = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return raw.map { display in
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).map { space in
                SpaceInfo(id: space["id64"] as? UInt64 ?? 0, kind: kind(of: space["type"] as? Int))
            }
            return DisplaySpaces(
                displayUUID: display["Display Identifier"] as? String ?? "",
                currentSpaceID: (display["Current Space"] as? [String: Any])?["id64"] as? UInt64,
                spaces: spaces
            )
        }
    }

    /// 窗口所在的 Space（含非当前 Space 和全屏 Space）
    public static func spaceIDs(forWindow wid: CGWindowID) -> [UInt64] {
        guard let mainConnection, let copySpacesForWindows else { return [] }
        let allSpacesMask: Int32 = 7
        return copySpacesForWindows(mainConnection(), allSpacesMask, [wid] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    }

    public static func spaceLocations() -> [UInt64: SpaceLocation] {
        var map: [UInt64: SpaceLocation] = [:]
        for display in displaySpaces() {
            for (i, space) in display.spaces.enumerated() {
                map[space.id] = SpaceLocation(id: space.id, displayUUID: display.displayUUID, index: i + 1, kind: space.kind)
            }
        }
        return map
    }

    public static func spaces(onDisplay uuid: String) -> DisplaySpaces? {
        displaySpaces().first { $0.displayUUID == uuid }
    }

    public static func location(ofWindow wid: CGWindowID) -> SpaceLocation? {
        let locations = spaceLocations()
        return spaceIDs(forWindow: wid).lazy.compactMap { locations[$0] }.first
    }

    private static func kind(of type: Int?) -> SpaceKind {
        switch type {
        case 0: .desktop
        case 4: .fullScreen
        default: .other
        }
    }
}

public enum AXBridge {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    nonisolated(unsafe) private static let handle = dlopen(nil, RTLD_LAZY)
    private static let getWindow: GetWindowFn? = symbol(handle, "_AXUIElementGetWindow")
    private static let createWithRemoteToken: CreateWithRemoteTokenFn? = symbol(handle, "_AXUIElementCreateWithRemoteToken")

    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard let getWindow, getWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// 应用的指定窗口，包括其它 Space 上的。
    /// `AXWindows` 只返回当前 Space 的窗口，缺的再用远程令牌枚举补齐（AltTab 同款做法），
    /// 找齐 `expected` 即停止，避免每个应用都扫满 1000 个元素 ID。
    public static func windows(pid: pid_t, expected: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var result: [CGWindowID: AXUIElement] = [:]
        let app = AXUIElementCreateApplication(pid)
        for window in AX.value(app, kAXWindowsAttribute) as [AXUIElement]? ?? [] {
            if let wid = windowID(of: window), expected.contains(wid) { result[wid] = window }
        }
        guard let createWithRemoteToken, result.count < expected.count else { return result }

        // 令牌格式：pid(4) + 0(4) + "coco"(4) + 元素 ID(8)
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            bytes.storeBytes(of: 0x636f_636f, toByteOffset: 8, as: Int32.self)
        }
        for elementID: UInt64 in 0..<1000 where result.count < expected.count {
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  AX.value(element, kAXRoleAttribute) as String? == kAXWindowRole,
                  let wid = windowID(of: element), expected.contains(wid) else { continue }
            result[wid] = result[wid] ?? element
        }
        return result
    }
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
    guard let handle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}
