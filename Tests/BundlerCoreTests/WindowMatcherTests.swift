import BundlerCore
import Testing

private func candidate(_ bundleID: String, _ title: String, _ windowID: UInt32? = nil) -> MatchCandidate {
    MatchCandidate(bundleID: bundleID, title: title, windowID: windowID)
}

@Suite struct WindowMatcherTests {
    @Test func windowIDWinsOverChangedTitle() {
        // Chrome 切换标签页后标题变了，但同一次登录内窗口 ID 不变
        let saved = [candidate("chrome", "GitHub", 10), candidate("chrome", "YouTube", 11)]
        let live = [candidate("chrome", "Gmail", 11), candidate("chrome", "X", 10)]
        #expect(WindowMatcher.match(saved: saved, live: live) == [0: 1, 1: 0])
    }

    @Test func exactTitleMatchesAfterReboot() {
        // 重启后 ID 全变了，靠标题认
        let saved = [candidate("ghostty", "api", 10), candidate("ghostty", "web", 11)]
        let live = [candidate("ghostty", "web", 500), candidate("ghostty", "api", 501)]
        #expect(WindowMatcher.match(saved: saved, live: live) == [0: 1, 1: 0])
    }

    @Test func leftoversPairByCreationOrder() {
        let saved = [candidate("chrome", "A", 1), candidate("chrome", "B", 2)]
        let live = [candidate("chrome", "Y", 900), candidate("chrome", "X", 800)]
        #expect(WindowMatcher.match(saved: saved, live: live) == [0: 1, 1: 0])
    }

    @Test func neverCrossesApps() {
        let saved = [candidate("chrome", "Docs")]
        let live = [candidate("safari", "Docs")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }

    @Test func eachLiveWindowUsedOnce() {
        let saved = [candidate("notes", "Notes"), candidate("notes", "Notes")]
        let live = [candidate("notes", "Notes", 5)]
        #expect(WindowMatcher.match(saved: saved, live: live) == [0: 0])
    }
}
