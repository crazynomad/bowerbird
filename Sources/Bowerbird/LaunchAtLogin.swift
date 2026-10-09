import BowerbirdCore
import Foundation
import ServiceManagement

/// 开机自动启动（系统设置 → 通用 → 登录项）。登记的是 App 当前所在路径，
/// 所以应从「应用程序」文件夹运行，否则移动项目目录后会失效。
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    /// 已登记但用户在系统设置里关掉了，需要用户去批准
    static var needsApproval: Bool { status == .requiresApproval }
    static var isInApplicationsFolder: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("开机自动启动设置失败：\(error.localizedDescription)")
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
