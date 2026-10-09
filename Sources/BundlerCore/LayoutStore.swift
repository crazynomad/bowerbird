import Foundation

public enum LayoutKind: Sendable {
    /// 用户手动保存（钉住），优先级最高，不会被自动记录覆盖
    case pinned
    /// 显示器稳定时后台定期记录的"最近一次正常布局"
    case learned

    var fileSuffix: String {
        switch self {
        case .pinned: ""
        case .learned: ".learned"
        }
    }
}

/// 每个显示器环境最多两份 JSON：~/Library/Application Support/MonitorBundler/Layouts/<环境键>[.learned].json
public struct LayoutStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MonitorBundler/Layouts", isDirectory: true)) {
        self.directory = directory
    }

    public func load(environmentKey: String, kind: LayoutKind) -> Layout? {
        guard let data = try? Data(contentsOf: url(for: environmentKey, kind: kind)) else { return nil }
        return try? Self.decoder.decode(Layout.self, from: data)
    }

    public func save(_ layout: Layout, kind: LayoutKind) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(layout).write(to: url(for: layout.environmentKey, kind: kind), options: .atomic)
    }

    public static func load(from url: URL) throws -> Layout {
        try decoder.decode(Layout.self, from: Data(contentsOf: url))
    }

    public static func encode(_ layout: Layout) throws -> Data { try encoder.encode(layout) }

    private func url(for key: String, kind: LayoutKind) -> URL {
        directory.appendingPathComponent("\(key)\(kind.fileSuffix).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
