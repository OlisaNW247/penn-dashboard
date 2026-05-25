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
        .executable(name: "low-hanging-fruit", targets: ["LowHangingFruitApp"]),
    ],
    targets: [
        .target(name: "LowHangingFruitKit"),
        .executableTarget(
            name: "LowHangingFruitApp",
            dependencies: ["LowHangingFruitKit"]
        ),
        .testTarget(
            name: "LowHangingFruitKitTests",
            dependencies: ["LowHangingFruitKit"]
        ),
    ]
)
