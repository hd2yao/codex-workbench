// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexWorkbench",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexWorkbenchCore", targets: ["CodexWorkbenchCore"]),
        .executable(name: "CodexWorkbenchApp", targets: ["CodexWorkbenchApp"]),
        .executable(name: "CodexWorkbenchLoginHelper", targets: ["CodexWorkbenchLoginHelper"]),
    ],
    targets: [
        .target(
            name: "CodexWorkbenchCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "CodexWorkbenchApp",
            dependencies: ["CodexWorkbenchCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "CodexWorkbenchLoginHelper",
            dependencies: ["CodexWorkbenchCore"],
            path: "Sources/LoginHelper"
        ),
        .executableTarget(
            name: "CodexWorkbenchCoreTests",
            dependencies: ["CodexWorkbenchCore"],
            path: "Tests/CodexWorkbenchCoreTests"
        ),
    ]
)
