import BowerbirdCore
import Foundation
import Testing

/// 用本机实测的公司布局（IDEAS.md 阶段 0）验证默认规则
@Suite struct LayoutMapperTests {
    let builtin = DisplayInfo(uuid: "BUILTIN", name: "Built-in", isBuiltin: true, frame: Rect(x: 0, y: 0, width: 1710, height: 1107))
    let vp2770 = DisplayInfo(uuid: "VP2770", name: "VP2770", isBuiltin: false, frame: Rect(x: -438, y: -1440, width: 2560, height: 1440))
    let vx3209 = DisplayInfo(uuid: "VX3209", name: "VX3209", isBuiltin: false, frame: Rect(x: 2122, y: -1440, width: 1920, height: 1080))
    let home = DisplayInfo(uuid: "HOME", name: "Home 4K", isBuiltin: false, frame: Rect(x: 0, y: -1080, width: 1920, height: 1080))

    func record(_ app: String, _ display: DisplayInfo, _ index: Int, fullScreen: Bool = true, frame: Rect? = nil) -> WindowRecord {
        WindowRecord(bundleID: app, appName: app, title: app, displayUUID: display.uuid,
                     frame: frame ?? Rect(x: 0, y: 0, width: display.frame.width, height: display.frame.height),
                     isFullScreen: fullScreen, spaceIndex: index)
    }

    var office: Layout {
        Layout(environmentKey: "office", name: "公司", savedAt: Date(), displays: [builtin, vp2770, vx3209], windows: [
            record("Mail", builtin, 1, fullScreen: false, frame: Rect(x: 0, y: 34, width: 1710, height: 1073)),
            record("Ghostty", builtin, 2),
            record("ChatGPT", builtin, 3),
            record("WeChat", vp2770, 1, fullScreen: false, frame: Rect(x: 1280, y: 720, width: 1110, height: 700)),
            record("Claude", vp2770, 2),
            record("Notes", vp2770, 3),
            record("Chrome", vx3209, 1),
        ])
    }

    func sequence(_ layout: Layout, _ display: DisplayInfo) -> [String] {
        layout.spaceSequence(on: display.uuid).map { $0.map { layout.windows[$0].appName } ?? "桌面" }
    }

    @Test func infersDesktopPositionWithoutNormalWindows() {
        #expect(sequence(office, vx3209) == ["Chrome", "桌面"])
        #expect(sequence(office, vp2770) == ["桌面", "Claude", "Notes"])
    }

    @Test func threeToTwoMergesExternalsAndKeepsBuiltin() {
        let derived = LayoutMapper.derive(from: office, to: DisplayEnvironment(displays: [builtin, home]))
        #expect(sequence(derived, builtin) == ["桌面", "Ghostty", "ChatGPT"])
        // 高分屏 VP2770 的 Space 在前，VX3209 的 Chrome 接在后面，两个桌面合一
        #expect(sequence(derived, home) == ["桌面", "Claude", "Notes", "Chrome"])
    }

    @Test func mergedNormalWindowsScaleIntoTarget() {
        let derived = LayoutMapper.derive(from: office, to: DisplayEnvironment(displays: [builtin, home]))
        let wechat = derived.windows.first { $0.appName == "WeChat" }!
        #expect(wechat.displayUUID == "HOME")
        #expect(wechat.frame == Rect(x: 960, y: 540, width: 1110, height: 700))
    }

    @Test func twoToThreeMapsToHigherResolutionExternal() {
        let homeLayout = Layout(environmentKey: "home", name: "家里", savedAt: Date(), displays: [builtin, home], windows: [
            record("Ghostty", builtin, 2), record("Claude", home, 2), record("Chrome", home, 3),
        ])
        let derived = LayoutMapper.derive(from: homeLayout, to: DisplayEnvironment(displays: [builtin, vx3209, vp2770]))
        #expect(sequence(derived, vp2770) == ["桌面", "Claude", "Chrome"])
        #expect(sequence(derived, vx3209) == ["桌面"])
        #expect(sequence(derived, builtin) == ["桌面", "Ghostty"])
    }

    @Test func builtinOnlyCollectsEverything() {
        let derived = LayoutMapper.derive(from: office, to: DisplayEnvironment(displays: [builtin]))
        #expect(sequence(derived, builtin) == ["桌面", "Ghostty", "ChatGPT", "Claude", "Notes", "Chrome"])
    }

    func foregrounds(_ layout: Layout) -> Set<String> {
        Set(layout.windows.filter { $0.isForeground == true }.map(\.appName))
    }

    @Test func mergeKeepsForegroundOfHigherResolutionSource() {
        // 公司：内建屏停在桌面，VP2770 停在 Claude，VX3209 停在 Chrome
        var layout = office
        layout.desktopForeground = ["BUILTIN"]
        for i in layout.windows.indices where ["Claude", "Chrome"].contains(layout.windows[i].appName) {
            layout.windows[i].isForeground = true
        }
        let derived = LayoutMapper.derive(from: layout, to: DisplayEnvironment(displays: [builtin, home]))
        #expect(foregrounds(derived) == ["Claude"])
        #expect(derived.desktopForeground == ["BUILTIN"])
    }

    @Test func mergeKeepsDesktopForegroundOfPrimarySource() {
        var layout = office
        layout.desktopForeground = ["VP2770"]
        for i in layout.windows.indices where layout.windows[i].appName == "Chrome" { layout.windows[i].isForeground = true }
        let derived = LayoutMapper.derive(from: layout, to: DisplayEnvironment(displays: [builtin, home]))
        #expect(foregrounds(derived).isEmpty)
        #expect(derived.desktopForeground == ["HOME"])
    }

    @Test func resolverPrefersPinnedThenLearnedThenDerived() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let homeEnvironment = DisplayEnvironment(displays: [builtin, home])
        try store.save(office, kind: .learned)

        let derived = LayoutResolver.resolve(for: homeEnvironment, previousEnvironmentKey: "office", store: store)
        #expect(derived?.1 == .derived(from: "公司"))

        var learnedHome = office
        learnedHome.environmentKey = homeEnvironment.key
        try store.save(learnedHome, kind: .learned)
        #expect(LayoutResolver.resolve(for: homeEnvironment, previousEnvironmentKey: "office", store: store)?.1 == .learned)

        try store.save(learnedHome, kind: .pinned)
        #expect(LayoutResolver.resolve(for: homeEnvironment, previousEnvironmentKey: "office", store: store)?.1 == .pinned)
    }
}
