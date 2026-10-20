// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SharedPlatformImportSmoke",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SharedPlatformImportSmoke",
            targets: ["SharedPlatformImportSmoke"]
        ),
        .library(
            name: "AppleContinuityImportSmoke",
            targets: ["AppleContinuityImportSmoke"]
        ),
        .executable(
            name: "SharedPlatformCABILinkSmoke",
            targets: ["SharedPlatformCABILinkSmoke"]
        ),
    ],
    dependencies: [
        .package(path: "../TesseraCore"),
        .package(path: "../TmuxControl"),
    ],
    targets: [
        .target(
            name: "SharedPlatformImportSmoke",
            dependencies: [
                .product(name: "TesseraDomainCore", package: "TesseraCore"),
                .product(name: "TesseraProtocolCore", package: "TesseraCore"),
                .product(name: "TesseraTrustCore", package: "TesseraCore"),
                .product(name: "TesseraContinuityCore", package: "TesseraCore"),
                .product(name: "TesseraCrossDeviceCore", package: "TesseraCore"),
                .product(name: "TesseraEnrollmentCore", package: "TesseraCore"),
                .product(name: "TesseraInputCore", package: "TesseraCore"),
                .product(name: "TesseraSessionCore", package: "TesseraCore"),
                .product(name: "TesseraPairingCore", package: "TesseraCore"),
                .product(name: "TesseraBootstrapCore", package: "TesseraCore"),
                .product(name: "TesseraCoreABI", package: "TesseraCore"),
                .product(name: "TmuxControlCore", package: "TmuxControl"),
            ]
        ),
        .testTarget(
            name: "SharedPlatformImportSmokeTests",
            dependencies: ["SharedPlatformImportSmoke"]
        ),
        .target(
            name: "AppleContinuityImportSmoke",
            dependencies: [
                .product(
                    name: "TesseraAppleContinuity",
                    package: "TesseraCore"
                ),
                .product(name: "TesseraEnrollmentCore", package: "TesseraCore"),
                .product(name: "TesseraSessionCore", package: "TesseraCore"),
            ]
        ),
        .testTarget(
            name: "AppleContinuityImportSmokeTests",
            dependencies: ["AppleContinuityImportSmoke"]
        ),
        .executableTarget(
            name: "SharedPlatformCABILinkSmoke",
            dependencies: [
                .product(name: "TesseraCoreABI", package: "TesseraCore"),
                .product(name: "TesseraCoreCABIHeaders", package: "TesseraCore"),
            ]
        ),
    ]
)
