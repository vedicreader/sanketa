// swift-tools-version: 6.2
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Sanketa",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        // the vishalakshi vault's SQLite core: a static library with SQLite and the `adhara` tokenizer built in
        .package(url: "https://github.com/vedicreader/adhara", exact: "0.1.2"),
    ],
    targets: [
        .target(name: "SanketaCore",
                dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")],
                swiftSettings: v5),
        .target(name: "SanketaSystem", dependencies: ["SanketaCore"], swiftSettings: v5),
        .target(name: "SanketaUI", dependencies: ["SanketaCore", "SanketaSystem"], swiftSettings: v5),
        .target(name: "SanketaAI", dependencies: ["SanketaCore"], swiftSettings: v5),
        // the only target that reads the vishalakshi vault; read-only, keyword search
        .target(name: "SanketaVault", dependencies: ["SanketaCore", .product(name: "Adhara", package: "adhara")],
                swiftSettings: v5),
        // the only target that imports MLX; its Metal shaders compile only under xcodebuild (make bundle)
        .target(name: "SanketaMLX",
                dependencies: ["SanketaCore", "SanketaAI",
                               .product(name: "MLXLLM", package: "mlx-swift-lm"),
                               .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                               .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                               .product(name: "Tokenizers", package: "swift-transformers")],
                swiftSettings: v5),
        .executableTarget(name: "Sanketa", dependencies: ["SanketaCore", "SanketaSystem", "SanketaUI", "SanketaAI", "SanketaMLX",
                                                          "SanketaVault"],
                          swiftSettings: v5),
        .testTarget(name: "SanketaCoreTests", dependencies: ["SanketaCore"],
                    resources: [.copy("Fixtures")], swiftSettings: v5),
        // test helper: an AppKit window whose title tests set through stdin
        .executableTarget(name: "SanketaTitleHost", swiftSettings: v5),
        .testTarget(name: "SanketaSystemTests", dependencies: ["SanketaCore", "SanketaSystem", "SanketaAI", "SanketaTitleHost", "Sanketa"], swiftSettings: v5),
        .testTarget(name: "SanketaUITests", dependencies: ["SanketaCore", "SanketaSystem", "SanketaUI", "SanketaTitleHost"],
                    swiftSettings: v5),
        .testTarget(name: "SanketaAITests", dependencies: ["SanketaAI", "SanketaCore"], swiftSettings: v5),
        .testTarget(name: "SanketaVaultTests", dependencies: ["SanketaVault", "SanketaCore", "SanketaUI"],
                    resources: [.copy("Fixtures")], swiftSettings: v5),
        .testTarget(name: "SanketaMLXTests", dependencies: ["SanketaMLX", "SanketaCore", "SanketaAI"], swiftSettings: v5),
    ]
)
