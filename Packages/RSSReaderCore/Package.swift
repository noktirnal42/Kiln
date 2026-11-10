// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RSSReaderCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "RSSReaderCore",
            targets: ["RSSReaderCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RSSReaderCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
