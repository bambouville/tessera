// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TesseraBridgeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TesseraBridgeCore", targets: ["TesseraBridgeCore"]),
    ],
    dependencies: [
        .package(path: "../TesseraCore"),
        .package(path: "../TmuxControl"),
    ],
    targets: [
        .target(
            name: "TesseraBridgeCore",
            dependencies: [
                .product(name: "TesseraDomainCore", package: "TesseraCore"),
                .product(name: "TesseraProtocolCore", package: "TesseraCore"),
                .product(name: "TmuxControlCore", package: "TmuxControl"),
            ]
        ),
        .testTarget(
            name: "TesseraBridgeCoreTests",
            dependencies: [
                "TesseraBridgeCore",
                .product(name: "TesseraProtocolCore", package: "TesseraCore"),
            ]
        ),
    ]
)
