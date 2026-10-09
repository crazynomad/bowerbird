import BowerbirdCore
import CoreGraphics
import Testing

@Suite struct FrameMapperTests {
    // 与本机实测布局一致：VP2770 在内建屏上方偏左
    let vp2770 = CGRect(x: -438, y: -1440, width: 2560, height: 1440)

    @Test func roundTripsThroughRelativeCoordinates() {
        let window = CGRect(x: -238, y: -1340, width: 1200, height: 800)
        let relative = FrameMapper.relative(window, to: vp2770)
        #expect(relative == Rect(x: 200, y: 100, width: 1200, height: 800))
        #expect(FrameMapper.place(relative, on: vp2770) == window)
    }

    @Test func shrinksAndShiftsIntoSmallerDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let placed = FrameMapper.place(Rect(x: 1500, y: 900, width: 2000, height: 600), on: laptop)
        #expect(placed == CGRect(x: 0, y: 507, width: 1710, height: 600))
    }

    @Test func toleratesSmallDrift() {
        let a = CGRect(x: 0, y: 34, width: 1710, height: 1073)
        #expect(FrameMapper.isClose(a, a.offsetBy(dx: 3, dy: -5)))
        #expect(!FrameMapper.isClose(a, a.offsetBy(dx: 40, dy: 0)))
    }
}
