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
        .executable(name: "penn-dashboard", targets: ["PennDashboardApp"]),
    ],
    targets: [
        .target(name: "PennDashboardKit"),
        .executableTarget(
            name: "PennDashboardApp",
            dependencies: ["PennDashboardKit"]
        ),
        .testTarget(
            name: "PennDashboardKitTests",
            dependencies: ["PennDashboardKit"]
        ),
    ]
)
