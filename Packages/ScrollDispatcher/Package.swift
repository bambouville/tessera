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
    dependencies: [
        // The routing rule itself lives in the shared core so Android's
        // Termux view answers the same question the same way.
        .package(path: "../TesseraCore"),
    ],
    targets: [
        .target(
            name: "ScrollDispatcher",
            dependencies: [
                .product(name: "TesseraInputCore", package: "TesseraCore"),
            ],
            path: "Sources/ScrollDispatcher"
        ),
        .testTarget(
            name: "ScrollDispatcherTests",
            dependencies: ["ScrollDispatcher"],
            path: "Tests/ScrollDispatcherTests"
        ),
    ]
)
