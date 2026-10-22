// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "promptscope",
    platforms: [.macOS(.v14)],
    targets: [
        // Parsers and library scan. No UI imports.
        .target(name: "PromptscopeKit", path: "Sources/PromptscopeKit"),
        .executableTarget(
            name: "promptscope-cli",
            dependencies: ["PromptscopeKit"],
            path: "Sources/promptscope-cli"
        ),
        .testTarget(
            name: "PromptscopeKitTests",
            dependencies: ["PromptscopeKit"],
            path: "Tests/PromptscopeKitTests",
            // Golden JSON is read from disk in the test. It is not a resource.
            exclude: ["Fixtures"]
        ),
    ]
)
