// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sparebar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Sparebar", targets: ["UsageApp"]),
        .executable(name: "sparebar-check", targets: ["UsageCheck"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "UsageProviders", dependencies: ["UsageCore"]),
        .executableTarget(name: "UsageApp", dependencies: ["UsageCore", "UsageProviders"]),
        .executableTarget(name: "UsageCheck", dependencies: ["UsageCore", "UsageProviders"]),
        .testTarget(name: "UsageTests", dependencies: ["UsageCore", "UsageProviders", "UsageApp"]),
    ]
)
