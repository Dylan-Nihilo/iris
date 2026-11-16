// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iris",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iris", targets: ["iris"]),
    ],
    targets: [
        .target(name: "IrisCore"),
        .executableTarget(name: "iris", dependencies: ["IrisCore"]),
        // A window that operates itself, to try iris on without an application of your own.
        .executableTarget(name: "iris-demo"),
        .testTarget(name: "IrisCoreTests", dependencies: ["IrisCore"]),
    ]
)
