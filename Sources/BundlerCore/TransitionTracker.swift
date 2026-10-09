/// 显示器环境切换的性质
public enum Transition: Equatable, Sendable {
    /// 暂时断开：新环境的显示器全在断开前的环境里（只是少了几块），例如在公司拔线只剩内建屏
    case disconnect
    /// 断开后接回原环境：macOS 会按显示器 UUID 原生恢复 Space 与窗口，不接管
    case reconnect
    /// 换到了另一组显示器（例如公司 → 家里）。`deriveFrom` 为推导默认布局时的来源环境
    case switched(deriveFrom: String)
}

/// 区分"暂时断开再接回"与"真正换环境"。
/// 断开期间若接管（尤其是重建全屏 Space），接回时 macOS 将认不出这些 Space，原生恢复反而失效。
public struct TransitionTracker: Sendable {
    /// 断开前的完整环境；断开期间保持不变（3 屏 → 2 屏 → 1 屏仍记 3 屏）
    public private(set) var disconnectedFrom: DisplayEnvironment?

    public init() {}

    public mutating func transition(from previous: DisplayEnvironment, to current: DisplayEnvironment) -> Transition {
        let currentDisplays = Set(current.displays.map(\.uuid))

        if let origin = disconnectedFrom {
            if current.key == origin.key {
                disconnectedFrom = nil
                return .reconnect
            }
            // 继续拔，或只接回了一部分
            if currentDisplays.isStrictSubset(of: Set(origin.displays.map(\.uuid))) { return .disconnect }
            disconnectedFrom = nil
            // 断开期间所有窗口都挤在剩下的屏上，推导要以断开前的环境为来源
            return .switched(deriveFrom: origin.key)
        }

        if currentDisplays.isStrictSubset(of: Set(previous.displays.map(\.uuid))) {
            disconnectedFrom = previous
            return .disconnect
        }
        return .switched(deriveFrom: previous.key)
    }
}
