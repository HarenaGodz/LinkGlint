// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LinkGlint",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LinkGlint", targets: ["LinkGlint"]),
        .executable(name: "LinkGlintHelper", targets: ["LinkGlintHelper"]),
        .library(name: "LinkGlintHelperSupport", targets: ["LinkGlintHelperSupport"])
    ],
    targets: [
        .target(name: "LinkGlintHelperSupport"),
        .executableTarget(
            name: "LinkGlint",
            linkerSettings: [
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN")
            ]
        ),
        .executableTarget(
            name: "LinkGlintHelper",
            dependencies: ["LinkGlintHelperSupport"]
        ),
        .testTarget(
            name: "LinkGlintTests",
            dependencies: ["LinkGlint", "LinkGlintHelperSupport"]
        )
    ]
)
