// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftBarcodeScanningUtils",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "SwiftBarcodeScanningUtils",
            targets: [
                "SwiftBarcodeScanningUtils",
            ]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(
            url: "https://github.com/CypherPoet/UnitIntervalPropertyWrapper",
            .upToNextMinor(from: "0.1.0")
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "SwiftBarcodeScanningUtils",
            dependencies: [
                "UnitIntervalPropertyWrapper",
            ],
            path: "Sources/SwiftBarcodeScanningUtils/",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "SwiftBarcodeScanningUtilsTests",
            dependencies: [
                "SwiftBarcodeScanningUtils",
            ],
            path: "Tests/SwiftBarcodeScanningUtils/",
            exclude: [
                "Resources/README.md",
                "Toolbox/README.md",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
