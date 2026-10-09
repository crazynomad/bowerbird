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
        UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? Bool ?? true
    }
}
