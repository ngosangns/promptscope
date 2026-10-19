// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "promptscope",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../ns-shell"),
    ],
    targets: [
        // Parsers and library scan. No UI imports.
        // Zed: crates/project, shared by the window and the CLI.
        .target(name: "PromptscopeKit", path: "Sources/PromptscopeKit"),
        // Composition root. App binds PromptscopeCommand. Design is the
        // component crate. See ../ARCHITECTURE.md.
        .executableTarget(
            name: "promptscope-app",
            dependencies: ["PromptscopeKit", .product(name: "NSShell", package: "ns-shell")],
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
