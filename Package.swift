// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PGDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PGDesk", targets: ["PGDesk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "PGDeskCore",
            dependencies: [.product(name: "PostgresNIO", package: "postgres-nio")]
        ),
        .executableTarget(
            name: "PGDesk",
            dependencies: ["PGDeskCore"]
        ),
        .testTarget(
            name: "PGDeskCoreTests",
            dependencies: ["PGDeskCore"]
        ),
    ]
)
