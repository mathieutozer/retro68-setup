// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "retro68-setup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "retro68-setup", targets: ["retro68-setup"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/tuist/Noora", from: "0.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "retro68-setup",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
    ]
)
