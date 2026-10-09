import CoreGraphics

/// 窗口坐标与显示器之间的换算（纯函数，便于测试）
public enum FrameMapper {
    public static func relative(_ frame: CGRect, to display: CGRect) -> Rect {
        Rect(frame.offsetBy(dx: -display.minX, dy: -display.minY))
    }

    /// 把相对坐标放回目标显示器；若显示器变小，先缩尺寸再平移，保证窗口完整落在屏内
    public static func place(_ relative: Rect, on display: CGRect) -> CGRect {
        let width = min(relative.width, display.width)
        let height = min(relative.height, display.height)
        let x = min(max(relative.x, 0), display.width - width)
        let y = min(max(relative.y, 0), display.height - height)
        return CGRect(x: display.minX + x, y: display.minY + y, width: width, height: height)
    }

    /// AX 回读的位置常有几个像素偏差（菜单栏、窗口最小尺寸等），容差内视为成功
    public static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
