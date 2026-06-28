// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeHop",
            path: "Sources/ClaudeSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
