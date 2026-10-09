import ApplicationServices

/// 公开 Accessibility 接口的薄封装
public enum AX {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示（仅在未授权时有效）
    public static func requestTrust() {
        // 即 kAXTrustedCheckOptionPrompt；该全局变量在 Swift 6 下被视为非并发安全
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    public static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// 先移位置再改尺寸再移一次：跨屏移动时，目标屏可能先按旧尺寸把窗口挤回边界内
    @discardableResult
    public static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        let second = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return first == .success || second == .success
    }

    public static func isFullScreen(_ element: AXUIElement) -> Bool { value(element, "AXFullScreen") ?? false }

    @discardableResult
    public static func setFullScreen(_ element: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, on as CFBoolean) == .success
    }

    /// 置为应用的主窗口并提到最前；随后激活应用时 macOS 会切到它所在的 Space
    public static func raise(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
    public static func isMinimized(_ element: AXUIElement) -> Bool { value(element, kAXMinimizedAttribute) ?? false }
    public static func title(of element: AXUIElement) -> String { value(element, kAXTitleAttribute) ?? "" }
}
