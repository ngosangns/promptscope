// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "promptscope",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: session models, Grok/Kiro parsers, library scan.
        // No UI imports, so it is unit-testable and reusable by the CLI.
        .target(name: "PromptscopeKit", path: "Sources/PromptscopeKit"),
        // SwiftUI app: state (Model), design system (Design), feature views.
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
