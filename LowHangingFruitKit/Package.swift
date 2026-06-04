// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LowHangingFruitKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LowHangingFruitKit", targets: ["LowHangingFruitKit"]),
        // App UI as a library so a real Xcode app target can import it and own @main.
        .library(name: "LowHangingFruitUI", targets: ["LowHangingFruitUI"]),
    ],
    targets: [
        .target(name: "LowHangingFruitKit"),
        .target(
            name: "LowHangingFruitUI",
            dependencies: ["LowHangingFruitKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LowHangingFruitKitTests",
            dependencies: ["LowHangingFruitKit", "LowHangingFruitUI"]
        ),
    ]
)
