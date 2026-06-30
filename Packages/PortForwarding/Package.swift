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
    targets: [
        .target(
            name: "PortForwarding",
            path: "Sources/PortForwarding"
        ),
        .testTarget(
            name: "PortForwardingTests",
            dependencies: ["PortForwarding"],
            path: "Tests/PortForwardingTests"
        ),
    ]
)
