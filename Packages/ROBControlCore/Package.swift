// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ROBControlCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "ROBControlCore", targets: ["ROBControlCore"]),
        .library(name: "ROBVideoPipeline", targets: ["ROBVideoPipeline"]),
    ],
    targets: [
        .target(name: "ROBControlCore"),
        .target(
            name: "ROBVideoPipeline",
            dependencies: ["ROBControlCore"]
        ),
        .testTarget(
            name: "ROBControlCoreTests",
            dependencies: ["ROBControlCore"]
        ),
        .testTarget(
            name: "ROBVideoPipelineTests",
            dependencies: ["ROBControlCore", "ROBVideoPipeline"]
        ),
    ]
)
