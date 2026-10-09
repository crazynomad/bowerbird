import CoreGraphics
import Foundation

/// JSON 里可读的矩形（CGRect 自带的 Codable 是嵌套数组，不便人工查看）
public struct Rect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var isBuiltin: Bool
    /// 全局坐标（左上角为原点，与 AX / CGDisplayBounds 一致）
    public var frame: Rect

    public init(uuid: String, name: String, isBuiltin: Bool, frame: Rect) {
        (self.uuid, self.name, self.isBuiltin, self.frame) = (uuid, name, isBuiltin, frame)
    }
}

/// 一组同时接入的显示器，用显示器 UUID 集合识别（不依赖屏幕数量或排列）
public struct DisplayEnvironment: Equatable, Sendable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) { self.displays = displays }

    public var key: String { displays.map(\.uuid).sorted().joined(separator: "+") }

    public var externalDisplays: [DisplayInfo] { displays.filter { !$0.isBuiltin } }

    /// 首次保存时给出的默认名，用户可修改
    public var suggestedName: String {
        switch externalDisplays.count {
        case 0: "仅内建屏"
        case 1: "家里"
        case 2: "公司"
        default: externalDisplays.map(\.name).joined(separator: " + ")
        }
    }

    public func display(uuid: String) -> DisplayInfo? { displays.first { $0.uuid == uuid } }
}

public struct WindowRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var displayUUID: String
    /// 相对所在显示器左上角
    public var frame: Rect
    public var isFullScreen: Bool
    /// 在所在显示器 Space 列表中的序号，从 1 开始
    public var spaceIndex: Int
    /// 仅在同一次登录内有效，用于配对标题会变的窗口
    public var windowID: UInt32?
    /// 全屏窗口且正是所在显示器当前显示的那一页
    public var isForeground: Bool?
    /// 保存时拥有键盘焦点
    public var isFocused: Bool?

    public init(bundleID: String, appName: String, title: String, displayUUID: String, frame: Rect, isFullScreen: Bool, spaceIndex: Int,
                windowID: UInt32? = nil, isForeground: Bool? = nil, isFocused: Bool? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.displayUUID = displayUUID
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.spaceIndex = spaceIndex
        self.windowID = windowID
        self.isForeground = isForeground
        self.isFocused = isFocused
    }

    public var matchCandidate: MatchCandidate { MatchCandidate(bundleID: bundleID, title: title, windowID: windowID) }
}

public struct Layout: Codable, Equatable, Sendable {
    public var environmentKey: String
    public var name: String
    public var savedAt: Date
    public var displays: [DisplayInfo]
    public var windows: [WindowRecord]
    /// 当前显示普通桌面的显示器；显示全屏页的显示器由 `WindowRecord.isForeground` 表示
    public var desktopForeground: [String]?

    public init(environmentKey: String, name: String, savedAt: Date, displays: [DisplayInfo], windows: [WindowRecord],
                desktopForeground: [String]? = nil) {
        self.environmentKey = environmentKey
        self.name = name
        self.savedAt = savedAt
        self.displays = displays
        self.windows = windows
        self.desktopForeground = desktopForeground
    }
}
