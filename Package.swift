// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "YouTrek",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "YouTrek",
            targets: ["YouTrek"]
        )
    ],
    dependencies: [
        // Core libraries that will power the production app. They are declared now so we can
        // wire them up incrementally while keeping the build green.
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.10.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.4.0"),
        .package(url: "https://github.com/kean/Nuke", from: "12.0.0"),
.package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.57.0"), 
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "1.7.5"),
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "YouTrek",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture", condition: .when(platforms: [.macOS])),
                .product(name: "Dependencies", package: "swift-dependencies", condition: .when(platforms: [.macOS])),
                .product(name: "Nuke", package: "Nuke", condition: .when(platforms: [.macOS])),
                .product(name: "Sentry", package: "sentry-cocoa", condition: .when(platforms: [.macOS])),
                // AppAuth releases a static library; we will bridge it via our own wrapper target in the repo.
                .product(name: "AppAuth", package: "AppAuth-iOS", condition: .when(platforms: [.macOS])),
                .product(name: "SQLite", package: "SQLite.swift", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/YouTrek",
            resources: [
                // Placeholder for future design assets (SFSymbol config, etc.)
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("DisableOutwardActorInference")
            ]
        ),
        .testTarget(
            name: "YouTrekTests",
            dependencies: ["YouTrek"],
            path: "Tests/YouTrekTests"
        )
    ]
)
