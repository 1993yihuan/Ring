// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ring",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Ring", targets: ["RingApp"]),
        .library(name: "RingCore", targets: ["RingCore"])
    ],
    targets: [
        .target(name: "RingCore"),
        .executableTarget(name: "RingApp", dependencies: ["RingCore"]),
        .testTarget(name: "RingCoreTests", dependencies: ["RingCore"])
    ],
    swiftLanguageModes: [.v5]
)
