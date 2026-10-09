import CoreGraphics

public struct MatchCandidate: Equatable, Sendable {
    public var bundleID: String
    public var title: String
    public var windowID: CGWindowID?

    public init(bundleID: String, title: String, windowID: CGWindowID?) {
        (self.bundleID, self.title, self.windowID) = (bundleID, title, windowID)
    }
}

/// 把保存的窗口记录与当前窗口配对。按可靠程度分三轮，每个窗口最多配对一次：
/// 1. 同应用 + 同 CGWindowID：同一次登录内稳定，标题变了也能认出（Chrome、终端）
/// 2. 同应用 + 标题完全相同：重启后 ID 会变，靠标题认
/// 3. 同应用剩余窗口按创建顺序（ID 升序）依次配对
public enum WindowMatcher {
    /// 返回 保存记录下标 → 当前窗口下标
    public static func match(saved: [MatchCandidate], live: [MatchCandidate]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var used = Set<Int>()
        let liveByCreation = live.indices.sorted { (live[$0].windowID ?? .max) < (live[$1].windowID ?? .max) }

        func pass(_ isMatch: (MatchCandidate, MatchCandidate) -> Bool) {
            for (s, record) in saved.enumerated() where result[s] == nil {
                guard let l = liveByCreation.first(where: { !used.contains($0) && live[$0].bundleID == record.bundleID && isMatch(record, live[$0]) })
                else { continue }
                result[s] = l
                used.insert(l)
            }
        }

        pass { saved, live in saved.windowID != nil && saved.windowID == live.windowID }
        pass { saved, live in saved.title == live.title }
        pass { _, _ in true }
        return result
    }
}
