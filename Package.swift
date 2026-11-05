// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "Meterline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meterline", targets: ["Meterline"])
    ],
    targets: [
        .executableTarget(
            name: "Meterline",
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
        .testTarget(name: "MeterlineTests", dependencies: ["Meterline"])
    ]
)
