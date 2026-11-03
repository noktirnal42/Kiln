// swift-tools-version: 6.0
import PackageDescription

/// A stand-in for Kiln on the Mac that speaks the remote-control protocol, for the companion's tests and for trying
/// the phone without a Mac build: `swift run fakemac` prints a pairing link and advertises over Bonjour.
let package = Package(
    name: "FakeMac",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "FakeMacKit", targets: ["FakeMacKit"]), .executable(name: "fakemac", targets: ["fakemac"])],
    dependencies: [.package(path: "../../../Packages/KilnRemoteKit")],
    targets: [
        .target(name: "FakeMacKit", dependencies: [.product(name: "KilnRemoteKit", package: "KilnRemoteKit")]),
        .executableTarget(name: "fakemac", dependencies: ["FakeMacKit"]),
    ]
)
