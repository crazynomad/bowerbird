import BowerbirdCore
import Foundation
import Testing

@Suite struct EnvironmentTests {
    let builtin = DisplayInfo(uuid: "37D8832A", name: "Built-in", isBuiltin: true, frame: Rect(x: 0, y: 0, width: 1710, height: 1107))
    let vp2770 = DisplayInfo(uuid: "605A4DD4", name: "VP2770 SERIES", isBuiltin: false, frame: Rect(x: -438, y: -1440, width: 2560, height: 1440))
    let vx3209 = DisplayInfo(uuid: "8789C85C", name: "VX3209-SW", isBuiltin: false, frame: Rect(x: 2122, y: -1440, width: 1920, height: 1080))

    @Test func keyIgnoresOrderAndArrangement() {
        var moved = vx3209
        moved.frame.x = -5000
        let office = DisplayEnvironment(displays: [builtin, vp2770, vx3209])
        let rearranged = DisplayEnvironment(displays: [moved, builtin, vp2770])
        #expect(office.key == rearranged.key)
    }

    @Test func suggestsNamesByExternalCount() {
        #expect(DisplayEnvironment(displays: [builtin, vp2770]).suggestedName == "家里")
        #expect(DisplayEnvironment(displays: [builtin, vp2770, vx3209]).suggestedName == "公司")
    }

    @Test func layoutSurvivesJSONRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directory: directory)
        let environment = DisplayEnvironment(displays: [builtin, vp2770])
        let layout = Layout(
            environmentKey: environment.key, name: "家里", savedAt: Date(timeIntervalSince1970: 1_790_000_000),
            displays: environment.displays,
            windows: [WindowRecord(bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "playground",
                                   displayUUID: "37D8832A", frame: Rect(x: 0, y: 34, width: 1710, height: 1073),
                                   isFullScreen: true, spaceIndex: 2, windowID: 8887)]
        )
        try store.save(layout, kind: .pinned)
        #expect(store.load(environmentKey: environment.key, kind: .pinned) == layout)
    }
}
