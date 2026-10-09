import AppKit
import BundlerCore

// 带子命令时作为命令行工具运行（便于调试），否则启动菜单栏应用
let arguments = Array(CommandLine.arguments.dropFirst())

if let command = arguments.first {
    exit(CLI.run(command: command, arguments: Array(arguments.dropFirst())))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
