// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorBundler",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BundlerCore"),
        .executableTarget(name: "MonitorBundler", dependencies: ["BundlerCore"]),
        .testTarget(name: "BundlerCoreTests", dependencies: ["BundlerCore"]),
    ]
)
