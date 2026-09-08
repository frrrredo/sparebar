// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sparebar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Sparebar", targets: ["UsageApp"]),
        .executable(name: "sparebar-check", targets: ["UsageCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "UsageProviders", dependencies: ["UsageCore"]),
        .executableTarget(
            name: "UsageApp",
            dependencies: ["UsageCore", "UsageProviders", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(name: "UsageCheck", dependencies: ["UsageCore", "UsageProviders"]),
        .testTarget(name: "UsageTests", dependencies: ["UsageCore", "UsageProviders", "UsageApp"]),
    ]
)
