// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScrollDispatcher",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScrollDispatcher", targets: ["ScrollDispatcher"]),
    ],
    targets: [
        .target(
            name: "ScrollDispatcher",
            path: "Sources/ScrollDispatcher"
        ),
        .testTarget(
            name: "ScrollDispatcherTests",
            dependencies: ["ScrollDispatcher"],
            path: "Tests/ScrollDispatcherTests"
        ),
    ]
)
