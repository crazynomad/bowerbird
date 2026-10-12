import AppKit
import BowerbirdCore
import SwiftUI

/// 发现新显示器时询问它的身份。不回答就一直按访客屏处理，绝不擅自整理
@MainActor
final class NewDisplayPrompt: NSWindowController {
    convenience init(display: DisplayInfo, answer: @escaping (DisplayRole) -> Void) {
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bowerbird"
        window.isReleasedWhenClosed = false
        window.level = .floating
        // 你可能正停在某个全屏应用的页上：询问必须出现在当前页，而不是开在别的 Space 里看不见
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 面板默认在 App 不处于前台时隐藏；而 macOS 14 起激活请求可能被拒，询问会一直藏着
        window.hidesOnDeactivate = false
        self.init(window: window)
        window.contentView = NSHostingView(rootView: NewDisplayView(display: display) { [weak self] role in
            // 先关窗口：answer 里调用方会释放本控制器，之后 self 已为 nil，窗口就关不掉了
            self?.close()
            answer(role)
        })
        window.center()
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        // 激活请求可能被系统拒绝（用户正在用别的应用），无论如何都把窗口放到最前
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

private struct NewDisplayView: View {
    let display: DisplayInfo
    let answer: (DisplayRole) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现新显示器：\(display.name)").font(.headline)
                    Text(verbatim: "\(Int(display.frame.width))×\(Int(display.frame.height))").foregroundStyle(.secondary)
                }
            }
            Text("在你确认之前，Bowerbird 不会把任何窗口挪到这块屏上。如果是会议室投影或临时借用的屏幕，选「临时投屏」，以后再接上它也不会打扰你。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("只是临时投屏，别动它") { answer(.guest) }
                Spacer()
                Button("这是我的工作屏，帮我整理") { answer(.work) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

/// 显示器管理：查看与修改每块屏的身份
@MainActor
final class DisplaysWindowController: NSWindowController {
    convenience init(model: DisplaysModel) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "显示器管理"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.init(window: window)
        window.contentView = NSHostingView(rootView: DisplaysView(model: model))
        window.center()
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        // 激活请求可能被系统拒绝（用户正在用别的应用），无论如何都把窗口放到最前
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

@MainActor @Observable
final class DisplaysModel {
    struct Row: Identifiable {
        let id: String
        let name: String
        let role: DisplayRole
        let confirmed: Bool
        let reason: String?
        let connected: Bool
    }

    var rows: [Row] = []
    let change: (String, DisplayRole) -> Void

    init(change: @escaping (String, DisplayRole) -> Void) { self.change = change }

    func reload(registry: DisplayRegistry, connected: Set<String>) {
        rows = registry.entries
            .map { Row(id: $0.key, name: $0.value.name, role: $0.value.role, confirmed: $0.value.confirmed,
                       reason: $0.value.reason, connected: connected.contains($0.key)) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }
}

private struct DisplaysView: View {
    let model: DisplaysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工作屏由 Bowerbird 管理；访客屏（会议室投影、电视等）会被完全无视。内建屏永远是工作屏。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.rows.isEmpty {
                Text("还没有登记过外接显示器。").foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.role == .work ? "display" : "tv").font(.title3).frame(width: 26)
                        .foregroundStyle(row.connected ? .primary : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.headline)
                        Text(detail(row)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { row.role }, set: { model.change(row.id, $0) })) {
                        Text("工作屏").tag(DisplayRole.work)
                        Text("访客屏").tag(DisplayRole.guest)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func detail(_ row: DisplaysModel.Row) -> String {
        var parts = [row.connected ? "已连接" : "未连接", String(row.id.prefix(8))]
        if !row.confirmed { parts.append("待确认") }
        if let reason = row.reason { parts.append("自动判定：\(reason)") }
        return parts.joined(separator: " · ")
    }
}
