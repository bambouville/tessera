// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PortForwarding",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PortForwarding", targets: ["PortForwarding"]),
    ],
    dependencies: [
        .package(path: "../TesseraCore"),
    ],
    targets: [
        .target(
            name: "PortForwarding",
            dependencies: [
                .product(name: "TesseraDomainCore", package: "TesseraCore"),
            ],
            path: "Sources/PortForwarding"
        ),
        .testTarget(
            name: "PortForwardingTests",
            dependencies: ["PortForwarding"],
            path: "Tests/PortForwardingTests"
        ),
    ]
)
