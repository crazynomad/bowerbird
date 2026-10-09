import Foundation

/// 项目由 Monitor Bundler 改名为 Bowerbird（2026-10-09），把旧位置的布局和日志一次性搬到新位置
public enum Migration {
    public static func moveLegacyData() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        let moves = [
            (support.appendingPathComponent("MonitorBundler"), support.appendingPathComponent("Bowerbird")),
            (logs.appendingPathComponent("MonitorBundler.log"), logs.appendingPathComponent("Bowerbird.log")),
        ]
        for (old, new) in moves where fileManager.fileExists(atPath: old.path) && !fileManager.fileExists(atPath: new.path) {
            try? fileManager.moveItem(at: old, to: new)
        }
    }
}
