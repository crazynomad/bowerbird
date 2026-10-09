import AppKit

public struct RestoreReport: Sendable {
    public var moved: [String] = []
    public var alreadyInPlace: [String] = []
    /// 原生全屏恢复属于阶段 2，本阶段只记录不处理
    public var skippedFullScreen: [String] = []
    public var notFound: [String] = []
    public var failed: [String] = []

    public init() {}

    public var summary: String {
        var parts = ["移动 \(moved.count)", "原位 \(alreadyInPlace.count)"]
        if !skippedFullScreen.isEmpty { parts.append("跳过全屏 \(skippedFullScreen.count)") }
        if !notFound.isEmpty { parts.append("未找到 \(notFound.count)") }
        if !failed.isEmpty { parts.append("失败 \(failed.count)") }
        return parts.joined(separator: "，")
    }

    public var details: String {
        [("移动", moved), ("跳过全屏", skippedFullScreen), ("未找到", notFound), ("失败", failed)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0)：\n" + $0.1.map { "  - \($0)" }.joined(separator: "\n") }
            .joined(separator: "\n")
    }
}

/// 恢复前各窗口的原始位置，按窗口元素直接还原，不依赖重新配对
public struct UndoPoint {
    public struct Entry {
        let element: AXUIElement
        let frame: CGRect
        let label: String
    }

    public var entries: [Entry] = []
    public var isEmpty: Bool { entries.isEmpty }

    public init() {}
}

@MainActor
public enum Restorer {
    public static func snapshot(of environment: DisplayEnvironment, name: String) -> Layout {
        let records = WindowCatalog.capture(in: environment)
            .sorted { $0.windowID < $1.windowID }
            .compactMap { window in environment.display(uuid: window.displayUUID).map { WindowRecord(window, display: $0) } }
        return Layout(environmentKey: environment.key, name: name, savedAt: Date(), displays: environment.displays, windows: records)
    }

    public static func restore(_ layout: Layout, in environment: DisplayEnvironment) -> (RestoreReport, UndoPoint) {
        var report = RestoreReport()
        var undo = UndoPoint()
        let live = WindowCatalog.capture(in: environment)
        let matches = WindowMatcher.match(saved: layout.windows.map(\.matchCandidate), live: live.map(\.matchCandidate))

        for (index, record) in layout.windows.enumerated() {
            let recordLabel = record.title.isEmpty ? record.appName : "\(record.appName)「\(record.title)」"
            guard let liveIndex = matches[index] else { report.notFound.append(recordLabel); continue }
            let window = live[liveIndex]
            if record.isFullScreen || window.isFullScreen { report.skippedFullScreen.append(window.label); continue }
            guard let display = environment.display(uuid: record.displayUUID) else {
                report.failed.append("\(window.label)：目标显示器未接入"); continue
            }

            let target = FrameMapper.place(record.frame, on: display.frame.cgRect)
            if window.displayUUID == display.uuid && FrameMapper.isClose(window.frame, target) {
                report.alreadyInPlace.append(window.label); continue
            }
            undo.entries.append(.init(element: window.element, frame: window.frame, label: window.label))
            if apply(target, to: window.element) {
                report.moved.append(window.label)
            } else {
                let actual = AX.frame(of: window.element).map { "\(Rect($0))" } ?? "未知"
                report.failed.append("\(window.label)：目标 \(Rect(target))，实际 \(actual)")
            }
        }
        return (report, undo)
    }

    public static func undo(_ point: UndoPoint) -> RestoreReport {
        var report = RestoreReport()
        for entry in point.entries {
            if apply(entry.frame, to: entry.element) {
                report.moved.append(entry.label)
            } else {
                report.failed.append(entry.label)
            }
        }
        return report
    }

    /// 设置后回读校验，不到位再试一次（有的应用会在下一帧才响应尺寸变化）
    private static func apply(_ frame: CGRect, to element: AXUIElement) -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
            AX.setFrame(element, frame)
            if let actual = AX.frame(of: element), FrameMapper.isClose(actual, frame) { return true }
        }
        return false
    }
}
