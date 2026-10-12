import AppKit

/// 显示器身份：只有工作屏参与环境识别、记录与恢复
public enum DisplayRole: String, Codable, Sendable {
    /// Bowerbird 管理它：家里、公司的显示器
    case work
    /// Bowerbird 完全无视它：会议室投影、电视、随航等临时屏
    case guest
}

/// 每块见过的外接显示器的身份。
///
/// 不确定时绝不把窗口挪到没见过的屏上：把会议室当成工作环境整理会把私人窗口投到大屏上，
/// 反过来只是需要手动摆一次窗口。所以新显示器先按访客屏处理，由用户确认一次后记住。
public struct DisplayRegistry: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var role: DisplayRole
        /// false 表示尚待用户确认（按访客屏处理）
        public var confirmed: Bool
        /// 自动判定的原因，例如"随航"；用户确认的为 nil
        public var reason: String?
        public var firstSeen: Date

        public init(name: String, role: DisplayRole, confirmed: Bool, reason: String?, firstSeen: Date) {
            self.name = name
            self.role = role
            self.confirmed = confirmed
            self.reason = reason
            self.firstSeen = firstSeen
        }
    }

    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// 内建屏永远是工作屏
    public func isWork(_ display: DisplayInfo) -> Bool {
        display.isBuiltin || entries[display.uuid]?.role == .work
    }

    /// Bowerbird 眼中的环境：去掉访客屏和未确认的新屏
    public func workEnvironment(_ environment: DisplayEnvironment) -> DisplayEnvironment {
        DisplayEnvironment(displays: environment.displays.filter(isWork))
    }

    /// 还没登记过的外接屏
    public func unknownDisplays(in environment: DisplayEnvironment) -> [DisplayInfo] {
        environment.displays.filter { !$0.isBuiltin && entries[$0.uuid] == nil }
    }

    public var pendingConfirmation: [String] {
        entries.filter { !$0.value.confirmed }.map(\.key).sorted()
    }

    public mutating func set(_ display: DisplayInfo, role: DisplayRole, confirmed: Bool, reason: String? = nil, now: Date = Date()) {
        let firstSeen = entries[display.uuid]?.firstSeen ?? now
        entries[display.uuid] = Entry(name: display.name, role: role, confirmed: confirmed, reason: reason, firstSeen: firstSeen)
    }

    /// 首次运行：已有布局里出现过的外接屏都是用户的工作屏
    public static func bootstrap(from layouts: [Layout], now: Date = Date()) -> DisplayRegistry {
        var registry = DisplayRegistry()
        for display in layouts.flatMap(\.displays) where !display.isBuiltin && registry.entries[display.uuid] == nil {
            registry.set(display, role: .work, confirmed: true, reason: "已有布局", now: now)
        }
        return registry
    }

    /// 能确定是临时投屏、无需询问的情况；返回原因
    public static func automaticGuestReason(for display: DisplayInfo) -> String? {
        // 随航（iPad）的显示器名固定包含 "Sidecar"
        if display.name.localizedCaseInsensitiveContains("Sidecar") { return "随航" }
        return nil
    }
}

/// 名册持久化在 ~/Library/Application Support/Bowerbird/displays.json
public struct DisplayRegistryStore: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bowerbird/displays.json")) {
        self.url = url
    }

    public func load() -> DisplayRegistry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DisplayRegistry.self, from: data)
    }

    public func save(_ registry: DisplayRegistry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(registry).write(to: url, options: .atomic)
    }
}

extension Displays {
    /// 任意两块屏处于镜像状态：多半在投屏演示，此时 Bowerbird 整体暂停
    public static var isMirroring: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}

extension LayoutStore {
    /// 目录中的全部布局（钉住与自动记录），用于首次运行时登记工作屏
    public func allLayouts() -> [Layout] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? LayoutStore.load(from: $0) }
    }
}
