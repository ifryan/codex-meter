// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "CodexMeter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexMeter", targets: ["CodexMeter"])
    ],
    targets: [
        .executableTarget(
            name: "CodexMeter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "CodexMeterTests", dependencies: ["CodexMeter"])
    ]
)
