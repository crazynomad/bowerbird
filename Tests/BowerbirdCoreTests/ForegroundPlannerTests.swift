import BowerbirdCore
import Foundation
import Testing

/// 场景：T1 在公司保存布局 → T2 在家换了前台 → T3 回公司恢复，前台应延续 T2
@Suite struct ForegroundPlannerTests {
    let builtin = DisplayInfo(uuid: "BUILTIN", name: "Built-in", isBuiltin: true, frame: Rect(x: 0, y: 0, width: 1710, height: 1107))
    let vp2770 = DisplayInfo(uuid: "VP2770", name: "VP2770", isBuiltin: false, frame: Rect(x: -438, y: -1440, width: 2560, height: 1440))
    let vx3209 = DisplayInfo(uuid: "VX3209", name: "VX3209", isBuiltin: false, frame: Rect(x: 2122, y: -1440, width: 1920, height: 1080))
    let lg = DisplayInfo(uuid: "LG", name: "LG", isBuiltin: false, frame: Rect(x: -643, y: -1692, width: 3008, height: 1692))

    var office: DisplayEnvironment { DisplayEnvironment(displays: [builtin, vp2770, vx3209]) }
    var home: DisplayEnvironment { DisplayEnvironment(displays: [builtin, lg]) }

    func record(_ app: String, _ display: DisplayInfo, _ index: Int, id: UInt32, fullScreen: Bool = true,
                foreground: Bool = false, focused: Bool = false) -> WindowRecord {
        WindowRecord(bundleID: app, appName: app, title: app, displayUUID: display.uuid,
                     frame: Rect(x: 0, y: 0, width: 800, height: 600), isFullScreen: fullScreen, spaceIndex: index,
                     windowID: id, isForeground: foreground ? true : nil, isFocused: focused ? true : nil)
    }

    /// T1：公司三块屏分别停在 Ghostty、Notes、Chrome，焦点在 Notes
    var officeT1: Layout {
        Layout(environmentKey: office.key, name: "公司", savedAt: Date(), displays: office.displays, windows: [
            record("Mail", builtin, 1, id: 1, fullScreen: false),
            record("Ghostty", builtin, 2, id: 2, foreground: true),
            record("ChatGPT", builtin, 3, id: 3),
            record("WeChat", vp2770, 1, id: 4, fullScreen: false),
            record("Claude", vp2770, 2, id: 5),
            record("Notes", vp2770, 3, id: 6, foreground: true, focused: true),
            record("Chrome", vx3209, 2, id: 7, foreground: true),
        ])
    }

    func ref(_ app: String, _ id: UInt32) -> WindowIdentity { WindowIdentity(bundleID: app, title: app, windowID: id) }

    func attention(_ pages: [(DisplayInfo, WindowIdentity?)], focused: WindowIdentity?, on focusedDisplay: DisplayInfo?) -> AttentionState {
        AttentionState(environmentKey: home.key, displays: home.displays,
                       pages: pages.map { .init(displayUUID: $0.0.uuid, fullScreen: $0.1) },
                       focused: focused, focusedDisplayUUID: focusedDisplay?.uuid, observedAt: Date())
    }

    func app(_ choice: ForegroundChoice?, in layout: Layout) -> String {
        switch choice {
        case .fullScreen(let record): layout.windows[record].appName
        case .desktop: "桌面"
        case nil: "不切换"
        }
    }

    @Test func withoutAttentionFollowsTargetLayout() {
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: nil)
        #expect(app(plan.pages["BUILTIN"], in: officeT1) == "Ghostty")
        #expect(app(plan.pages["VP2770"], in: officeT1) == "Notes")
        #expect(plan.focus == 5)
    }

    @Test func todaysMorningCarriesHomeAttentionToOffice() {
        // 实测 T2（10-12 早上）：内建屏 ChatGPT，LG 停在桌面，焦点 ChatGPT
        let t2 = attention([(builtin, ref("ChatGPT", 3)), (lg, nil)], focused: ref("ChatGPT", 3), on: builtin)
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: t2)
        #expect(app(plan.pages["BUILTIN"], in: officeT1) == "ChatGPT")
        // LG 的桌面映射到分辨率更高的 VP2770，借它桌面上的微信切过去
        #expect(plan.pages["VP2770"] == .desktop(via: 3))
        // 家里没有对应 VX3209 的屏，保留 T1
        #expect(app(plan.pages["VX3209"], in: officeT1) == "Chrome")
        #expect(plan.focus == 2)
    }

    @Test func followsAppToWhicheverScreenItLivesOn() {
        // 在家 LG 上看 Claude，到公司 Claude 住在 VP2770
        let t2 = attention([(builtin, ref("Ghostty", 2)), (lg, ref("Claude", 5))], focused: ref("Claude", 5), on: lg)
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: t2)
        #expect(app(plan.pages["VP2770"], in: officeT1) == "Claude")
        #expect(app(plan.pages["BUILTIN"], in: officeT1) == "Ghostty")
        #expect(plan.focus == 4)
    }

    @Test func focusedPageWinsWhenTwoAppsShareTargetScreen() {
        // Claude 和 Notes 在公司都住在 VP2770，只能显示一个：焦点在 Notes，Notes 赢
        let t2 = attention([(builtin, ref("Claude", 5)), (lg, ref("Notes", 6))], focused: ref("Notes", 6), on: lg)
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: t2)
        #expect(app(plan.pages["VP2770"], in: officeT1) == "Notes")
    }

    @Test func appThatIsNotFullScreenAtTargetShowsItsDesktop() {
        let t2 = attention([(builtin, ref("Mail", 1))], focused: ref("Mail", 1), on: builtin)
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: t2)
        #expect(plan.pages["BUILTIN"] == .desktop(via: 0))
        #expect(plan.focus == 0)
    }

    @Test func matchesByTitleAfterRestart() {
        // 重启后窗口 ID 全变，按应用和标题认
        let t2 = attention([(lg, ref("Claude", 9999))], focused: nil, on: nil)
        let plan = ForegroundPlanner.plan(layout: officeT1, environment: office, attention: t2)
        #expect(app(plan.pages["VP2770"], in: officeT1) == "Claude")
        #expect(plan.focus == 5)  // 没有新焦点时保留 T1 的
    }
}
