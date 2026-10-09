import AppKit
import BowerbirdCore

/// 监听显示器变化，等配置稳定后才回调。
/// 扩展坞插拔会在几秒内连续触发多次变化，每次都重新计时。
@MainActor
final class DisplayMonitor {
    private let settleDelay: TimeInterval
    private let onSettled: @MainActor () -> Void
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// 每次变化加一，后台记录前后比对，发现期间有变化就丢弃结果
    private(set) var changeCount = 0
    private var lastChange = Date.distantPast

    /// 变化尚未稳定：此时 macOS 可能正在挤压窗口，不能保存布局
    var isSettling: Bool { timer != nil }

    /// 自上次变化起已稳定超过指定时长
    func isStable(for seconds: TimeInterval) -> Bool {
        !isSettling && Date().timeIntervalSince(lastChange) >= seconds
    }

    init(settleDelay: TimeInterval = 3, onSettled: @escaping @MainActor () -> Void) {
        self.settleDelay = settleDelay
        self.onSettled = onSettled
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
    }

    private func displaysChanged() {
        changeCount += 1
        lastChange = Date()
        Log.write("显示器配置变化，\(settleDelay)s 后检查")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.onSettled()
            }
        }
    }
}
