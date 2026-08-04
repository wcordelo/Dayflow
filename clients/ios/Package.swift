// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DayflowMobile",
    // macOS is listed only so this package can run wire-contract tests on the
    // development Mac. The shipped mobile target remains iOS 17+.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DayflowMobile", targets: ["DayflowMobile"]),
    ],
    targets: [
        .binaryTarget(
            name: "DayflowCore",
            path: "../../shared-core/dist/DayflowCoreiOS.xcframework"
        ),
        .target(
            name: "DayflowCoreBindings",
            dependencies: ["DayflowCore"]
        ),
        .target(name: "DayflowMobile", dependencies: ["DayflowCoreBindings"]),
        .testTarget(name: "DayflowMobileTests", dependencies: ["DayflowMobile"]),
    ]
)
