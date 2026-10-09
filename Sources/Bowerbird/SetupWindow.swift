import AppKit
import BowerbirdCore
import SwiftUI

/// 各项授权与设置的当前状态。设置窗口打开或缺少必需权限时每秒刷新，
/// 用户在系统设置里打勾后无需重启 App 即可生效。
@MainActor @Observable
final class SetupStatus {
    var accessibility = AX.isTrusted
    var rearrangesSpaces = MissionControl.rearrangesSpacesAutomatically
    var launchAtLogin = LaunchAtLogin.isEnabled
    var launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    var inApplicationsFolder = LaunchAtLogin.isInApplicationsFolder

    func refresh() {
        accessibility = AX.isTrusted
        rearrangesSpaces = MissionControl.rearrangesSpacesAutomatically
        launchAtLogin = LaunchAtLogin.isEnabled
        launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    }
}

@MainActor
final class SetupWindowController: NSWindowController {
    convenience init(status: SetupStatus) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bowerbird 设置"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = NSHostingView(rootView: SetupView(status: status) { [weak self] in self?.close() })
        window.center()
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SetupView: View {
    let status: SetupStatus
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "bird.fill").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Bowerbird").font(.title2.bold())
                    Text("园丁鸟会记住每块屏上的窗口和 Space，换环境后帮你摆回原位。").foregroundStyle(.secondary)
                }
            }

            CheckRow(
                isDone: status.accessibility, isRequired: true,
                title: "辅助功能权限",
                detail: status.accessibility
                    ? "已授权。"
                    : "必需，用于读取和移动窗口。点按钮后在列表里给 Bowerbird 打勾，这里会自动变成 ✅。",
                actionTitle: "打开系统设置"
            ) {
                AX.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            CheckRow(
                isDone: !status.rearrangesSpaces, isRequired: false,
                title: "关闭「根据最近的使用情况自动重新排列空间」",
                detail: status.rearrangesSpaces
                    ? "推荐。开启时 macOS 会按使用顺序打乱 Space，恢复好的顺序保持不住。关闭时 Dock 会闪一下，窗口不受影响。"
                    : "已关闭。",
                actionTitle: "一键关闭"
            ) {
                MissionControl.disableAutomaticRearrangement()
            }

            CheckRow(
                isDone: status.launchAtLogin, isRequired: false,
                title: "开机自动启动",
                detail: status.launchAtLoginNeedsApproval
                    ? "需要在 系统设置 → 通用 → 登录项 里允许 Bowerbird。"
                    : status.launchAtLogin ? "已开启。" : "推荐。否则重启电脑后需要手动打开。",
                actionTitle: status.launchAtLoginNeedsApproval ? "去批准" : "开启"
            ) {
                if status.launchAtLoginNeedsApproval {
                    LaunchAtLogin.openSettings()
                } else {
                    LaunchAtLogin.setEnabled(true)
                    status.refresh()
                }
            }

            if !status.inApplicationsFolder {
                Label("Bowerbird 不在「应用程序」文件夹里：移动它所在的目录后，开机自动启动会失效。",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(status.accessibility ? "完成" : "稍后再说", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct CheckRow: View {
    let isDone: Bool
    let isRequired: Bool
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : isRequired ? "exclamationmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isDone ? .green : isRequired ? .red : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isDone {
                Button(actionTitle, action: action)
            }
        }
    }
}
