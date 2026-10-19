// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModelLabCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "ModelLabCore",
            targets: ["ModelLabCore"]
        ),
        .executable(
            name: "ModelLabSmoke",
            targets: ["ModelLabSmoke"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "ModelLabCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .testTarget(
            name: "ModelLabCoreTests",
            dependencies: ["ModelLabCore"]
        ),
        .executableTarget(
            name: "ModelLabSmoke",
            dependencies: ["ModelLabCore"]
        )
    ]
)
