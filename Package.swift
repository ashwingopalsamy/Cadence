// swift-tools-version: 6.2
import PackageDescription

// Linux-safe targets. These build and test on Linux in the cloud and on macOS.
let core: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "CadenceCore",
        dependencies: [
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ],
        exclude: ["Store/Schema.sql"]
    ),
    .target(name: "CadenceIngest", dependencies: ["CadenceCore"]),
    .target(name: "CadenceMCP", dependencies: ["CadenceCore", "CadenceIngest"]),
    .executableTarget(
        name: "cadence",
        dependencies: [
            "CadenceCore", "CadenceIngest", "CadenceMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    // Tests read shared fixtures from Tests/Vectors via #filePath.
    .testTarget(name: "CadenceCoreTests", dependencies: ["CadenceCore"]),
    .testTarget(name: "CadenceIngestTests", dependencies: ["CadenceIngest"]),
    .testTarget(name: "CadenceMCPTests", dependencies: ["CadenceMCP"]),
]

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "cadence", targets: ["cadence"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: core
)

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]
for target in package.targets where target.type != .system {
    target.swiftSettings = (target.swiftSettings ?? []) + swiftSettings
}

#if os(macOS)
// The manifest is evaluated on the host, so Linux never sees the AppKit and SwiftUI targets.
package.targets += [
    .target(name: "CadenceUI", dependencies: ["CadenceCore"], swiftSettings: swiftSettings),
    .executableTarget(
        name: "CadenceApp",
        dependencies: ["CadenceUI", "CadenceCore", "CadenceIngest"],
        swiftSettings: swiftSettings
    ),
    .testTarget(name: "CadenceUITests", dependencies: ["CadenceUI"], swiftSettings: swiftSettings),
]
package.products += [.executable(name: "CadenceApp", targets: ["CadenceApp"])]
#endif
