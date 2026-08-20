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
            dependencies: ["LowHangingFruitKit", "LowHangingFruitUI"],
            // Recorded Canvas feed exports. The ICS tests were all built from
            // strings written by hand to match what the parser already did,
            // which cannot catch the case that matters: Canvas changing the
            // shape of what it actually sends.
            resources: [.process("Fixtures")]
        ),
    ]
)
