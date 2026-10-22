// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "kme",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "kme"
        ),
        .testTarget(
            name: "kmeTests",
            dependencies: ["kme"]
        ),
    ]
)
