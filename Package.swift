// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nuxie",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "Nuxie",
            targets: ["Nuxie"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", from: "2.5.0"),
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
        .testTarget(
            name: "NuxieTests",
            dependencies: [
                "Nuxie",
                "Quick",
                "Nimble"
            ],
            path: "Tests/NuxieTests"
        ),
    ]
)