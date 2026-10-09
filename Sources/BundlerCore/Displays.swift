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
