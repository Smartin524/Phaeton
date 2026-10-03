// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FormatWheel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FormatWheel", targets: ["FormatWheel"]),
        .library(name: "FormatWheelCore", targets: ["FormatWheelCore"])
    ],
    targets: [
        .target(name: "FormatWheelCore"),
        .executableTarget(name: "FormatWheel", dependencies: ["FormatWheelCore"]),
        .testTarget(name: "FormatWheelCoreTests", dependencies: ["FormatWheelCore"])
    ]
)
