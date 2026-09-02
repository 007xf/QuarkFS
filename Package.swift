// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuarkFS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuarkFSCore", targets: ["QuarkFSCore"]),
        .executable(name: "QuarkFS", targets: ["QuarkFS"]),
        .executable(name: "QuarkFSSmokeTests", targets: ["QuarkFSSmokeTests"])
    ],
    targets: [
        .target(
            name: "QuarkFSCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "QuarkFS",
            dependencies: ["QuarkFSCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage")
            ]
        ),
        .executableTarget(
            name: "QuarkFSSmokeTests",
            dependencies: ["QuarkFSCore"]
        )
    ]
)
