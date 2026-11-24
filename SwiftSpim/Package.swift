// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let debuggerTests: [Target] = [.testTarget(name: "SwiftSpimTests", dependencies: ["SwiftSpim", "SpimCore"])]
#else
let debuggerTests: [Target] = []
#endif

let package = Package(
    name: "SwiftSpim",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpimCore", targets: ["SpimCore"]),
        .executable(name: "SwiftSpim", targets: ["SwiftSpim"]),
        .executable(name: "swiftspim-cli", targets: ["SpimCLI"])
    ],
    targets: [
        .target(name: "SpimCore", resources: [.copy("Resources/exceptions.s")]),
        .executableTarget(name: "SwiftSpim", dependencies: ["SpimCore"]),
        .executableTarget(name: "SpimCLI", dependencies: ["SpimCore"]),
        .testTarget(name: "SpimCoreTests", dependencies: ["SpimCore"], resources: [.copy("Fixtures")])
    ] + debuggerTests,
    swiftLanguageVersions: [.v5]
)
