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
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Charts"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "CodexMeterTests", dependencies: ["CodexMeter"])
    ]
)
