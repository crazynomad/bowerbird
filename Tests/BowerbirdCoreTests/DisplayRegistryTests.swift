import BowerbirdCore
import Foundation
import Testing

/// 会议室投屏：访客屏不参与环境识别，所以既不会被整理，也不会打乱"公司"的判断
@Suite struct DisplayRegistryTests {
    let builtin = DisplayInfo(uuid: "BUILTIN", name: "Built-in", isBuiltin: true, frame: Rect(x: 0, y: 0, width: 1710, height: 1107))
    let vp2770 = DisplayInfo(uuid: "VP2770", name: "VP2770", isBuiltin: false, frame: Rect(x: -438, y: -1440, width: 2560, height: 1440))
    let vx3209 = DisplayInfo(uuid: "VX3209", name: "VX3209", isBuiltin: false, frame: Rect(x: 2122, y: -1440, width: 1920, height: 1080))
    let projector = DisplayInfo(uuid: "EPSON", name: "EPSON PJ", isBuiltin: false, frame: Rect(x: 1710, y: 0, width: 1920, height: 1080))

    var office: DisplayEnvironment { DisplayEnvironment(displays: [builtin, vp2770, vx3209]) }

    var registry: DisplayRegistry {
        DisplayRegistry.bootstrap(from: [Layout(environmentKey: office.key, name: "公司", savedAt: Date(), displays: office.displays, windows: [])])
    }

    @Test func bootstrapMarksDisplaysFromLayoutsAsWork() {
        #expect(registry.entries["VP2770"]?.role == .work)
        #expect(registry.entries["VX3209"]?.role == .work)
        #expect(registry.entries["BUILTIN"] == nil)  // 内建屏无需登记，永远是工作屏
    }

    @Test func projectorAddedAtOfficeLeavesEnvironmentUnchanged() {
        var registry = registry
        let withProjector = DisplayEnvironment(displays: [builtin, vp2770, vx3209, projector])
        #expect(registry.unknownDisplays(in: withProjector) == [projector])
        // 新屏先按访客屏处理（待确认）
        registry.set(projector, role: .guest, confirmed: false)
        #expect(registry.workEnvironment(withProjector).key == office.key)
        #expect(registry.pendingConfirmation == ["EPSON"])
    }

    @Test func projectorAloneLooksLikeLaptopOnlyAndIsTreatedAsDisconnect() {
        var registry = registry
        registry.set(projector, role: .guest, confirmed: true)
        let meeting = registry.workEnvironment(DisplayEnvironment(displays: [builtin, projector]))
        #expect(meeting.displays == [builtin])
        var tracker = TransitionTracker()
        #expect(tracker.transition(from: office, to: meeting) == .disconnect)
        #expect(tracker.transition(from: meeting, to: office) == .reconnect)
    }

    @Test func confirmingAsWorkBringsDisplayIntoEnvironment() {
        var registry = registry
        let lg = DisplayInfo(uuid: "LG", name: "LG", isBuiltin: false, frame: Rect(x: 0, y: -1692, width: 3008, height: 1692))
        registry.set(lg, role: .guest, confirmed: false)
        #expect(registry.workEnvironment(DisplayEnvironment(displays: [builtin, lg])).displays == [builtin])
        registry.set(lg, role: .work, confirmed: true)
        #expect(registry.workEnvironment(DisplayEnvironment(displays: [builtin, lg])).displays == [builtin, lg])
        #expect(registry.pendingConfirmation.isEmpty)
    }

    @Test func sidecarIsRecognizedWithoutAsking() {
        let ipad = DisplayInfo(uuid: "IPAD", name: "Sidecar Display (AirPlay)", isBuiltin: false, frame: Rect(x: 0, y: 0, width: 1180, height: 820))
        #expect(DisplayRegistry.automaticGuestReason(for: ipad) == "随航")
        #expect(DisplayRegistry.automaticGuestReason(for: vp2770) == nil)
    }
}
