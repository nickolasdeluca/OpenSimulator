// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSimulator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenSimulator", targets: ["OpenSimulator"]),
        .executable(name: "opensim", targets: ["opensim"]),
    ],
    targets: [
        // Objective-C bridge to Xcode's private CoreSimulator and SimulatorKit frameworks.
        // Nothing is linked: the frameworks are dlopen'd from the selected Xcode at runtime.
        .target(name: "SimBridge"),
        .target(name: "SimulatorCore", dependencies: ["SimBridge"]),
        .executableTarget(name: "OpenSimulator", dependencies: ["SimulatorCore", "SimBridge"]),
        // The command line tool, for scripts and agents that drive a simulator without the app.
        .executableTarget(name: "opensim", dependencies: ["SimulatorCore", "SimBridge"]),
        .testTarget(name: "SimulatorCoreTests", dependencies: ["SimulatorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
