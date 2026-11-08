// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StylePolish", platforms: [.macOS(.v13)], products: [
    .executable(name: "StylePolish", targets: ["StylePolishApp"])
], targets: [
    .target(name: "StylePolishCore"),
    .executableTarget(name: "StylePolishApp", dependencies: ["StylePolishCore"], exclude: ["Resources/AppIcon.icns"], resources: [.copy("Resources/prompts")]),
    .testTarget(name: "StylePolishCoreTests", dependencies: ["StylePolishCore"]),
    .testTarget(name: "StylePolishAppTests", dependencies: ["StylePolishApp"])
])
