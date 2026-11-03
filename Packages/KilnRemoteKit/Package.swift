// swift-tools-version: 6.0
import PackageDescription

/// The wire contract between Kiln on the Mac and its iOS and watchOS companions: messages, pairing and the
/// encrypted framing. No networking lives here, so every platform shares the same tested code.
let package = Package(
    name: "KilnRemoteKit",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "KilnRemoteKit", targets: ["KilnRemoteKit"])],
    targets: [
        .target(name: "KilnRemoteKit"),
        .testTarget(name: "KilnRemoteKitTests", dependencies: ["KilnRemoteKit"]),
    ]
)
