// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "swiftplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swiftplay", targets: ["swiftplay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "swiftplay",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
