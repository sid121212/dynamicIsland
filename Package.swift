// swift-tools-version: 5.9
import PackageDescription

// Resolve Sparkle's verified binary artifact with SwiftPM; build.sh assembles the app.
let package = Package(
    name: "DynamicIslandDependencies",
    platforms: [.macOS("15.0")],
    products: [.library(name: "UpdateDependencies", targets: ["UpdateDependencies"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [.target(name: "UpdateDependencies", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Dependencies")]
)
