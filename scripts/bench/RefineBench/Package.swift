// swift-tools-version: 6.1
// 離線跑 VoiceInk Refine 的補標點引擎(App 裡的同一份原始碼),比對輸出和速度。
// 不要直接 build,用 scripts/bench/refine-bench.sh(會把原始碼複製進來、套用 App 的套件版本)。
import PackageDescription

let package = Package(
    name: "RefineBench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "cd1ab3dd98ceb02d095490aa25e61298ea3e2f5b"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "RefineBench",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
