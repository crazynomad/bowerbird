import Foundation

/// 追加写入 ~/Library/Logs/MonitorBundler.log，便于事后排查恢复结果
public enum Log {
    public static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MonitorBundler.log")

    public static func write(_ message: String) {
        let line = "[\(Date().formatted(.iso8601))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
