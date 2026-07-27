// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppBox",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppBoxKit", targets: ["AppBoxKit"]),
        .executable(name: "appbox", targets: ["appbox"]),
        .executable(name: "AppBoxApp", targets: ["AppBoxApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // All policy and logic lives here so the CLI and the menu bar app share
        // one implementation and cannot drift apart.
        .target(name: "AppBoxKit"),
        .executableTarget(
            name: "appbox",
            dependencies: [
                "AppBoxKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The menu bar app. SPM cannot produce a .app bundle, so this target
        // builds a bare executable that `build-app.sh` assembles into one.
        .executableTarget(name: "AppBoxApp", dependencies: ["AppBoxKit"]),
        .testTarget(name: "AppBoxKitTests", dependencies: ["AppBoxKit"]),
    ]
)
