// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "LangCheck",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LangCheck"
        )
    ],
    swiftLanguageModes: [.v5]   // avoid Swift 6 strict-concurrency friction for a GUI app
)
