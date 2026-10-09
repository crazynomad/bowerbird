// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bowerbird",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BowerbirdCore"),
        .executableTarget(name: "Bowerbird", dependencies: ["BowerbirdCore"]),
        .testTarget(name: "BowerbirdCoreTests", dependencies: ["BowerbirdCore"]),
    ]
)
