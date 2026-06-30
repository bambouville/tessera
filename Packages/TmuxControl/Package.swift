// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TmuxControl",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TmuxControl", targets: ["TmuxControl"]),
    ],
    targets: [
        .target(
            name: "TmuxControl",
            path: "Sources/TmuxControl"
        ),
        .testTarget(
            name: "TmuxControlTests",
            dependencies: ["TmuxControl"],
            path: "Tests/TmuxControlTests"
        ),
    ]
)
