// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScanDeck",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ScanDeckCore",
            targets: ["ScanDeckCore"]
        ),
        .library(
            name: "ScanDeckScanner",
            targets: ["ScanDeckScanner"]
        ),
        .library(
            name: "ScanDeckImagePipeline",
            targets: ["ScanDeckImagePipeline"]
        ),
        .executable(
            name: "ScanDeck",
            targets: ["ScanDeckApp"]
        ),
        .executable(
            name: "scandeck-m0",
            targets: ["ScanDeckM0"]
        )
    ],
    targets: [
        .target(
            name: "ScanDeckCore"
        ),
        .target(
            name: "ScanDeckScanner",
            dependencies: ["ScanDeckCore"],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .target(
            name: "ScanDeckImagePipeline",
            dependencies: ["ScanDeckCore"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "ScanDeckApp",
            dependencies: [
                "ScanDeckCore",
                "ScanDeckImagePipeline",
                "ScanDeckScanner"
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "ScanDeckM0",
            dependencies: ["ScanDeckScanner"]
        ),
        .testTarget(
            name: "ScanDeckCoreTests",
            dependencies: ["ScanDeckCore"]
        ),
        .testTarget(
            name: "ScanDeckImagePipelineTests",
            dependencies: [
                "ScanDeckCore",
                "ScanDeckImagePipeline"
            ]
        ),
        .testTarget(
            name: "ScanDeckAppTests",
            dependencies: [
                "ScanDeckApp",
                "ScanDeckCore",
                "ScanDeckScanner"
            ]
        )
    ]
)
