// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "swiftplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swiftplay", targets: ["swiftplay"]),
        .executable(name: "swiftplay-menubar", targets: ["SwiftplayMenuBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Shared model layer (Config) so the CLI and the menu-bar app read/write
        // exactly one config schema — no drift.
        .target(name: "SwiftplayCore"),
        // Plain-C wrapper over the private CGVirtualDisplay API, so the Swift
        // target never touches the private ObjC classes directly.
        .target(name: "CVirtualDisplay"),
        .executableTarget(
            name: "swiftplay",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "CVirtualDisplay",
                "SwiftplayCore",
            ],
            resources: [
                // Brand typeface (Geist) bundled so rendered captions/titles match
                // the website. Registered at runtime by FontLoader.
                .copy("Resources/fonts"),
            ]
        ),
        // Menu-bar "control center" — edits the same config the CLI reads.
        .executableTarget(
            name: "SwiftplayMenuBar",
            dependencies: ["SwiftplayCore"]
        ),
        // Pure-logic unit tests. Everything that drives a real app needs
        // Accessibility (TCC) permission and a GUI, so it lives in the example
        // suites instead; this target covers the decision-making that can be
        // checked without either — starting with the keyboard's
        // character → virtual-keycode mapping.
        .testTarget(
            name: "KeyboardTests",
            dependencies: ["swiftplay"]
        ),
    ]
)
