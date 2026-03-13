// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nuxie",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Nuxie",
            targets: ["Nuxie"]
        ),
        .library(
            name: "NuxieRevenueCat",
            targets: ["NuxieRevenueCat"]
        ),
        .library(
            name: "NuxieSuperwall",
            targets: ["NuxieSuperwall"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", from: "2.5.0"),
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", branch: "main"),
        .package(url: "https://github.com/superwall/Superwall-iOS.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "Nuxie",
            dependencies: [
                .product(name: "FactoryKit", package: "Factory")
            ],
            path: "Sources/Nuxie",
            linkerSettings: [
                .linkedFramework("WebKit")
            ]
        ),
        .target(
            name: "NuxieTestSupport",
            dependencies: [
                "Nuxie",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieTestSupport"
        ),
        .testTarget(
            name: "NuxieUnitTests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieUnitTests"
        ),
        .testTarget(
            name: "NuxieIntegrationTests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieIntegrationTests"
        ),
        .testTarget(
            name: "NuxieE2ETests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieE2ETests"
        ),
        .target(
            name: "NuxieRevenueCat",
            dependencies: [
                "Nuxie",
                .product(name: "RevenueCat", package: "purchases-ios")
            ],
            path: "Sources/NuxieRevenueCat"
        ),
        .target(
            name: "NuxieSuperwall",
            dependencies: [
                "Nuxie",
                .product(
                    name: "SuperwallKit",
                    package: "Superwall-iOS",
                    condition: .when(platforms: [.iOS])
                )
            ],
            path: "Sources/NuxieSuperwall"
        ),
    ]
)
