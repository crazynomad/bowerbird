import AppKit
import BundlerCore

/// 监听显示器变化，等配置稳定后才回调。
/// 扩展坞插拔会在几秒内连续触发多次变化，每次都重新计时。
@MainActor
final class DisplayMonitor {
    private let settleDelay: TimeInterval
    private let onSettled: @MainActor () -> Void
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// 变化尚未稳定：此时 macOS 可能正在挤压窗口，不能保存布局
    var isSettling: Bool { timer != nil }

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
