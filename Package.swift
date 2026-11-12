// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StylePolish", platforms: [.macOS(.v13)], products: [
    .executable(name: "StylePolish", targets: ["StylePolishApp"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
], targets: [
    .target(name: "StylePolishCore", resources: [.copy("Resources/local-typos.json"), .copy("Resources/habit-tips.json"), .copy("Resources/apps.json")]),
    .executableTarget(
        name: "StylePolishApp",
        dependencies: ["StylePolishCore", .product(name: "Sparkle", package: "Sparkle")],
        exclude: ["Resources/AppIcon.icns"],
        resources: [.copy("Resources/prompts")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "StylePolishCoreTests", dependencies: ["StylePolishCore"]),
    .testTarget(name: "StylePolishAppTests", dependencies: ["StylePolishApp"])
])
