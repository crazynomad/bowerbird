import AppKit
import BowerbirdCore

Migration.moveLegacyData()

// 带子命令时作为命令行工具运行（便于调试），否则启动菜单栏应用
let arguments = Array(CommandLine.arguments.dropFirst())

if let command = arguments.first {
    Task { exit(await CLI.run(command: command, arguments: Array(arguments.dropFirst()))) }
    dispatchMain()
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
