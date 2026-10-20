// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TesseraCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TesseraDomainCore", targets: ["TesseraDomainCore"]),
        .library(name: "TesseraProtocolCore", targets: ["TesseraProtocolCore"]),
        .library(name: "TesseraTrustCore", targets: ["TesseraTrustCore"]),
        .library(name: "TesseraInputCore", targets: ["TesseraInputCore"]),
        .library(name: "TesseraSessionCore", targets: ["TesseraSessionCore"]),
        .library(name: "TesseraPairingCore", targets: ["TesseraPairingCore"]),
        .library(name: "TesseraBootstrapCore", targets: ["TesseraBootstrapCore"]),
        .library(name: "TesseraEnrollmentCore", targets: ["TesseraEnrollmentCore"]),
        .library(name: "TesseraContinuityCore", targets: ["TesseraContinuityCore"]),
        .library(name: "TesseraCrossDeviceCore", targets: ["TesseraCrossDeviceCore"]),
        .library(name: "TesseraAppleContinuity", targets: ["TesseraAppleContinuity"]),
        .library(name: "TesseraAgentCore", targets: ["TesseraAgentCore"]),
        .library(name: "TesseraCoreCABIHeaders", targets: ["TesseraCoreCABIHeaders"]),
        .library(name: "TesseraCoreABI", targets: ["TesseraCoreABI", "TesseraCoreCABIHeaders"]),
        .library(
            name: "TesseraCoreAndroid",
            type: .dynamic,
            targets: ["TesseraCoreABI"]
        ),
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(path: "../TmuxControl"),
    ],
    targets: [
        .target(name: "TesseraDomainCore"),
        .target(
            name: "TesseraProtocolCore",
            dependencies: [
                "TesseraDomainCore",
                .product(name: "TmuxControlCore", package: "TmuxControl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TesseraTrustCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "TesseraInputCore"),
        .target(
            name: "TesseraSessionCore",
            dependencies: [
                "TesseraDomainCore",
                "TesseraTrustCore",
                .product(name: "TmuxControlCore", package: "TmuxControl"),
            ]
        ),
        .target(
            name: "TesseraPairingCore",
            dependencies: [
                "TesseraProtocolCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TesseraEnrollmentCore",
            dependencies: [
                "TesseraPairingCore",
                "TesseraSessionCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TesseraBootstrapCore",
            dependencies: [
                "TesseraProtocolCore",
                "TesseraPairingCore",
                "TesseraEnrollmentCore",
                "TesseraSessionCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TesseraContinuityCore",
            dependencies: [
                "TesseraDomainCore",
                "TesseraProtocolCore",
                "TesseraPairingCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TesseraCrossDeviceCore",
            dependencies: [
                "TesseraPairingCore",
                "TesseraBootstrapCore",
                "TesseraContinuityCore",
                "TesseraEnrollmentCore",
                "TesseraSessionCore",
            ]
        ),
        .target(
            name: "TesseraAppleContinuity",
            dependencies: [
                "TesseraProtocolCore",
                "TesseraEnrollmentCore",
            ]
        ),
        .target(name: "TesseraAgentCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(
            name: "TesseraCoreABI",
            dependencies: [
                "TesseraDomainCore",
                "TesseraProtocolCore",
                "TesseraTrustCore",
                "TesseraInputCore",
                "TesseraSessionCore",
                "TesseraPairingCore",
                "TesseraBootstrapCore",
                "TesseraEnrollmentCore",
                "TesseraContinuityCore",
                "TesseraCrossDeviceCore",
                .product(name: "TmuxControlCore", package: "TmuxControl"),
                "TesseraAgentCore",
            ]
        ),
        .target(
            name: "TesseraCoreCABIHeaders",
            path: "Sources/TesseraCoreCABIHeaders",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TesseraCore",
            dependencies: [
                "TesseraDomainCore",
                "TesseraProtocolCore",
                "TesseraTrustCore",
                "TesseraInputCore",
                "TesseraSessionCore",
                "TesseraPairingCore",
                "TesseraBootstrapCore",
                "TesseraEnrollmentCore",
                "TesseraContinuityCore",
                "TesseraCrossDeviceCore",
                "TesseraCoreABI",
                "TesseraAgentCore",
            ]
        ),
        .testTarget(name: "TesseraDomainCoreTests", dependencies: ["TesseraDomainCore"]),
        .testTarget(name: "TesseraProtocolCoreTests", dependencies: ["TesseraProtocolCore"]),
        .testTarget(name: "TesseraTrustCoreTests", dependencies: ["TesseraTrustCore"]),
        .testTarget(name: "TesseraInputCoreTests", dependencies: ["TesseraInputCore"]),
        .testTarget(
            name: "TesseraAgentCoreTests",
            dependencies: ["TesseraAgentCore"],
            resources: [.process("Vectors")]
        ),
        .testTarget(name: "TesseraSessionCoreTests", dependencies: ["TesseraSessionCore"]),
        .testTarget(
            name: "TesseraCoreABITests",
            dependencies: [
                "TesseraCoreABI",
                .product(name: "TmuxControlCore", package: "TmuxControl"),
                "TesseraTrustCore",
                "TesseraPairingCore",
                "TesseraProtocolCore",
                "TesseraContinuityCore",
                "TesseraEnrollmentCore",
            ]
        ),
        .testTarget(
            name: "TesseraPairingCoreTests",
            dependencies: [
                "TesseraPairingCore",
                "TesseraContinuityCore",
                "TesseraBootstrapCore",
            ]
        ),
        .testTarget(
            name: "TesseraBootstrapCoreTests",
            dependencies: [
                "TesseraBootstrapCore",
                "TesseraPairingCore",
                "TesseraEnrollmentCore",
                "TesseraProtocolCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "TesseraEnrollmentCoreTests", dependencies: ["TesseraEnrollmentCore"]),
        .testTarget(
            name: "TesseraCrossDeviceCoreTests",
            dependencies: [
                "TesseraCrossDeviceCore",
                "TesseraPairingCore",
                "TesseraBootstrapCore",
                "TesseraContinuityCore",
                "TesseraEnrollmentCore",
                "TesseraProtocolCore",
                "TesseraSessionCore",
            ]
        ),
        .testTarget(
            name: "TesseraContinuityCoreTests",
            dependencies: ["TesseraContinuityCore", "TesseraPairingCore"]
        ),
        .testTarget(
            name: "TesseraAppleContinuityTests",
            dependencies: [
                "TesseraAppleContinuity",
                "TesseraProtocolCore",
                "TesseraEnrollmentCore",
            ]
        ),
    ]
)
