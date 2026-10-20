// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TmuxControl",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TmuxControlCore", targets: ["TmuxControlCore"]),
        .library(name: "TmuxControl", targets: ["TmuxControl"]),
    ],
    targets: [
        .target(
            name: "TmuxControl",
            dependencies: ["TmuxControlCore"],
            path: "Sources/TmuxControl"
        ),
        .target(
            name: "TmuxControlCore",
            path: "Sources/TmuxControlCore"
        ),
        .testTarget(
            name: "TmuxControlTests",
            dependencies: ["TmuxControl", "TmuxControlCore"],
            path: "Tests/TmuxControlTests"
        ),
        .testTarget(
            name: "TmuxControlCoreTests",
            dependencies: ["TmuxControlCore"],
            path: "Tests/TmuxControlCoreTests"
        ),
        // Test support only: a deterministic model of the tmux server rules the
        // grid-authority protocol depends on. It is not a product, so no app or
        // production target can link it; test targets depend on it directly.
        .target(
            name: "TmuxSemanticsModel",
            path: "Tests/Support/TmuxSemanticsModel"
        ),
        .testTarget(
            name: "TmuxSemanticsModelTests",
            dependencies: ["TmuxSemanticsModel", "TmuxControlCore"],
            path: "Tests/TmuxSemanticsModelTests",
            exclude: ["Scenarios"]
        ),
    ]
)
