// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SessionSwitch", path: "Sources/SessionSwitch"),
        .testTarget(name: "SessionSwitchTests", dependencies: ["SessionSwitch"], path: "Tests/SessionSwitchTests"),
    ]
)
