/// 一块显示器上 Space 序列中的一项：普通桌面，或某个窗口独占的全屏 Space
public enum SpaceSlot: Hashable, Sendable {
    case desktop
    case window(UInt32)
}

/// 让某窗口进入全屏的一步：先让显示器切到 `after`，新全屏 Space 就会插在它紧后面
public struct FullScreenStep: Equatable, Sendable {
    public let windowID: UInt32
    public let after: SpaceSlot

    public init(windowID: UInt32, after: SpaceSlot) {
        self.windowID = windowID
        self.after = after
    }
}

public struct SpacePlan: Equatable, Sendable {
    public var steps: [FullScreenStep]
    /// 目标要求全屏排在普通桌面之前，但没有可借用的锚点，只能退而排在桌面之后
    public var demotedBeforeDesktop: Bool
}

/// 规划一块显示器上的全屏重排（纯函数）。
///
/// 依据阶段 0b 实测：新的全屏 Space 插在显示器"当前 Space"的紧后面；普通桌面无法移动。
/// 因此保留目标序列与当前序列最长的公共前缀不动，其后的全屏窗口依次以前一项为锚点重新进入全屏。
public enum SpacePlanner {
    public static func plan(desired: [SpaceSlot], current: [SpaceSlot]) -> SpacePlan {
        var desired = desired
        if !desired.contains(.desktop) { desired.insert(.desktop, at: 0) }
        let relevant = current.filter(desired.contains)

        var keep = commonPrefixLength(desired, relevant)
        var demoted = false
        // 前缀为空且目标以全屏开头：桌面前面没有锚点可借，只能把桌面提到最前
        if keep == 0, desired.first != .desktop {
            desired.removeAll { $0 == .desktop }
            desired.insert(.desktop, at: 0)
            keep = commonPrefixLength(desired, relevant)
            demoted = true
        }

        var anchor = keep > 0 ? desired[keep - 1] : .desktop
        var steps: [FullScreenStep] = []
        for slot in desired.dropFirst(keep) {
            guard case .window(let id) = slot else { anchor = .desktop; continue }
            steps.append(FullScreenStep(windowID: id, after: anchor))
            anchor = slot
        }
        return SpacePlan(steps: steps, demotedBeforeDesktop: demoted)
    }

    private static func commonPrefixLength(_ a: [SpaceSlot], _ b: [SpaceSlot]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
