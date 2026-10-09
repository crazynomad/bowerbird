import BowerbirdCore
import Testing

@Suite struct SpacePlannerTests {
    let claude = SpaceSlot.window(5646), notes = SpaceSlot.window(2983), chrome = SpaceSlot.window(152)

    @Test func alreadyInOrderDoesNothing() {
        let plan = SpacePlanner.plan(desired: [.desktop, claude, notes], current: [.desktop, claude, notes])
        #expect(plan.steps.isEmpty)
    }

    @Test func swappedPairReentersFromFirstMismatch() {
        // 阶段 0b 的真实情况：Notes 插到了 Claude 前面
        let plan = SpacePlanner.plan(desired: [.desktop, claude, notes], current: [.desktop, notes, claude])
        #expect(plan.steps == [FullScreenStep(windowID: 5646, after: .desktop), FullScreenStep(windowID: 2983, after: claude)])
    }

    @Test func appendsMissingWindowAfterLastKept() {
        // 3 屏 → 2 屏：Chrome 要从别的屏并过来，排在 Notes 后面
        let plan = SpacePlanner.plan(desired: [.desktop, claude, notes, chrome], current: [.desktop, claude, notes])
        #expect(plan.steps == [FullScreenStep(windowID: 152, after: notes)])
    }

    @Test func keepsFullScreenBeforeDesktopWhenAlreadyThere() {
        // VX3209：Chrome 在桌面之前，已就位就不动
        let plan = SpacePlanner.plan(desired: [chrome, .desktop], current: [chrome, .desktop])
        #expect(plan.steps.isEmpty)
        #expect(!plan.demotedBeforeDesktop)
    }

    @Test func demotesWhenNothingToAnchorBeforeDesktop() {
        let plan = SpacePlanner.plan(desired: [chrome, .desktop], current: [.desktop])
        #expect(plan.steps == [FullScreenStep(windowID: 152, after: .desktop)])
        #expect(plan.demotedBeforeDesktop)
    }

    @Test func anchorsBeforeDesktopOnKeptFullScreen() {
        // 桌面前已有 Chrome，Notes 可以借 Chrome 当锚点插到桌面之前
        let plan = SpacePlanner.plan(desired: [chrome, notes, .desktop], current: [chrome, .desktop])
        #expect(plan.steps == [FullScreenStep(windowID: 2983, after: chrome)])
        #expect(!plan.demotedBeforeDesktop)
    }

    @Test func ignoresUnrelatedFullScreenWindows() {
        let stranger = SpaceSlot.window(999)
        let plan = SpacePlanner.plan(desired: [.desktop, claude], current: [.desktop, stranger, claude])
        #expect(plan.steps.isEmpty)
    }

    @Test func desktopAfterMismatchResetsAnchor() {
        let plan = SpacePlanner.plan(desired: [chrome, .desktop, notes], current: [chrome, notes, .desktop])
        #expect(plan.steps == [FullScreenStep(windowID: 2983, after: .desktop)])
    }
}
