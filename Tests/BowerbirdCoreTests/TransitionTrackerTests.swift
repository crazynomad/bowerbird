import BowerbirdCore
import Testing

@Suite struct TransitionTrackerTests {
    func display(_ uuid: String, builtin: Bool = false) -> DisplayInfo {
        DisplayInfo(uuid: uuid, name: uuid, isBuiltin: builtin, frame: Rect(x: 0, y: 0, width: 1920, height: 1080))
    }

    var builtin: DisplayInfo { display("BUILTIN", builtin: true) }
    var office: DisplayEnvironment { DisplayEnvironment(displays: [builtin, display("VP2770"), display("VX3209")]) }
    var officeMinusOne: DisplayEnvironment { DisplayEnvironment(displays: [builtin, display("VP2770")]) }
    var laptop: DisplayEnvironment { DisplayEnvironment(displays: [builtin]) }
    var home: DisplayEnvironment { DisplayEnvironment(displays: [builtin, display("HOME")]) }

    @Test func unplugAndReplugAtOfficeIsLeftToMacOS() {
        var tracker = TransitionTracker()
        #expect(tracker.transition(from: office, to: laptop) == .disconnect)
        #expect(tracker.transition(from: laptop, to: office) == .reconnect)
        #expect(tracker.disconnectedFrom == nil)
    }

    @Test func partialUnplugAndStepwiseReplugStaysDisconnected() {
        var tracker = TransitionTracker()
        #expect(tracker.transition(from: office, to: officeMinusOne) == .disconnect)
        #expect(tracker.transition(from: officeMinusOne, to: laptop) == .disconnect)
        #expect(tracker.transition(from: laptop, to: officeMinusOne) == .disconnect)
        #expect(tracker.transition(from: officeMinusOne, to: office) == .reconnect)
    }

    @Test func goingHomeAfterUnplugDerivesFromOffice() {
        // 公司拔线 → 路上只有内建屏 → 家里接上：推导来源是公司，而不是挤成一团的内建屏
        var tracker = TransitionTracker()
        #expect(tracker.transition(from: office, to: laptop) == .disconnect)
        #expect(tracker.transition(from: laptop, to: home) == .switched(deriveFrom: office.key))
        #expect(tracker.disconnectedFrom == nil)
    }

    @Test func directSwitchBetweenEnvironments() {
        var tracker = TransitionTracker()
        #expect(tracker.transition(from: home, to: office) == .switched(deriveFrom: home.key))
        // 家里 → 公司不是断开（多了屏），公司 → 家里也不是（HOME 不在公司环境里）
        #expect(tracker.transition(from: office, to: home) == .switched(deriveFrom: office.key))
    }
}
