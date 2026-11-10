// swift-tools-version: 6.0
import PackageDescription

// A trimmed, local-folder fork of mlx-swift-examples' StableDiffusion library (MIT, Apple Inc.; see LICENSE.upstream).
// Changes: loads a diffusers-layout folder from disk instead of downloading through a Hugging Face client; reads
// half-precision weights when the folder has them; SD 2.x architecture gets image-to-image and a distilled
// (Turbo) sampler. Kept as its own module because it declares an `Image` type that would shadow SwiftUI's.
let package = Package(
    name: "KilnDiffusion",
    platforms: [.macOS(.v15)],
    products: [.library(name: "KilnDiffusion", targets: ["KilnDiffusion"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
    ],
    targets: [
        .target(
            name: "KilnDiffusion",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
