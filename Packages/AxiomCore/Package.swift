// swift-tools-version: 6.0
import PackageDescription
// AxiomCore is dependency-free (Foundation + CryptoKit + CommonCrypto +
// JavaScriptCore + Darwin + Compression). Language mode v5 keeps it out of
// Swift 6 strict concurrency; the Kiln module wrapper supplies the
// @MainActor surface the app requires.
let package = Package(
    name: "AxiomRE",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AxiomCore", targets: ["AxiomCore"])
    ],
    targets: [
        .target(
            name: "AxiomCore"
        ),
        .testTarget(
            name: "AxiomCoreTests",
            dependencies: ["AxiomCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
