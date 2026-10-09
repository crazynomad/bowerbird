import AppKit

public enum Displays {
    @MainActor
    public static func currentEnvironment() -> DisplayEnvironment {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = uuid(of: id) else { return nil }
            return DisplayInfo(uuid: uuid, name: screen.localizedName, isBuiltin: CGDisplayIsBuiltin(id) != 0, frame: Rect(CGDisplayBounds(id)))
        }
        return DisplayEnvironment(displays: displays)
    }

    public static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

public enum MissionControl {
    /// 系统设置 → 桌面与程序坞 →"根据最近的使用情况自动重新排列空间"。未设置时默认开启。
    /// 开启时 macOS 会按使用顺序挪动 Space，与恢复 Space 顺序相冲突。
    public static var rearrangesSpacesAutomatically: Bool {
        // 设置可能在 App 运行期间被修改，读之前先与磁盘同步
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString) as? Bool ?? true
    }

    /// 关闭自动重排并重启 Dock 使其生效（Dock 会闪一下，窗口和 Space 不受影响）
    public static func disableAutomaticRearrangement() {
        CFPreferencesSetAppValue("mru-spaces" as CFString, false as CFBoolean, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }
}
