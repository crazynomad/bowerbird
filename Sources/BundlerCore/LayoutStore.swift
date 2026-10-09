import Foundation

/// 每个显示器环境一份 JSON：~/Library/Application Support/MonitorBundler/Layouts/<环境键>.json
public struct LayoutStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MonitorBundler/Layouts", isDirectory: true)) {
        self.directory = directory
    }

    public func load(environmentKey: String) -> Layout? {
        guard let data = try? Data(contentsOf: url(for: environmentKey)) else { return nil }
        return try? Self.decoder.decode(Layout.self, from: data)
    }

    public func save(_ layout: Layout) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(layout).write(to: url(for: layout.environmentKey), options: .atomic)
    }

    private func url(for key: String) -> URL { directory.appendingPathComponent("\(key).json") }

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
