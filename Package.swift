// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "promptscope",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PromptscopeKit", path: "Sources/PromptscopeKit"),
        .executableTarget(
            name: "promptscope-app",
            dependencies: ["PromptscopeKit"],
            path: "Sources/promptscope-app"
        ),
        .executableTarget(
            name: "promptscope-cli",
            dependencies: ["PromptscopeKit"],
            path: "Sources/promptscope-cli"
        ),
        .testTarget(
            name: "PromptscopeKitTests",
            dependencies: ["PromptscopeKit"],
            path: "Tests/PromptscopeKitTests"
        ),
    ]
)
