// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PennDashboardKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PennDashboardKit", targets: ["PennDashboardKit"]),
    ],
    targets: [
        .target(name: "PennDashboardKit"),
        .testTarget(
            name: "PennDashboardKitTests",
            dependencies: ["PennDashboardKit"]
        ),
    ]
)
