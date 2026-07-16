// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NetBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NetBar", targets: ["NetBar"]),
        .executable(name: "NetBarHelper", targets: ["NetBarHelper"])
    ],
    targets: [
        .executableTarget(name: "NetBar"),
        .executableTarget(name: "NetBarHelper"),
        .testTarget(name: "NetBarTests", dependencies: ["NetBar"])
    ]
)
