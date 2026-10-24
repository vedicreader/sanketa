import Foundation

/// One file of a model, with the size and SHA-256 pinned from the Hugging Face commit.
public struct ModelFile: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public init(name: String, size: Int64, sha256: String) { self.name = name; self.size = size; self.sha256 = sha256 }
}

/// A model at one pinned Hugging Face commit, and the files Sanketa downloads from it.
public struct ModelSpec: Sendable, Equatable {
    public let choice: MLXModelChoice
    public let repo: String
    public let revision: String
    public let folder: String
    public let files: [ModelFile]
    public init(choice: MLXModelChoice, repo: String, revision: String, folder: String, files: [ModelFile]) {
        self.choice = choice; self.repo = repo; self.revision = revision; self.folder = folder; self.files = files
    }

    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<name>`
    public func url(_ f: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(f.name)")!
    }
}

/// The pinned models. Values checked on 2026-10-24 with the HF API and `shasum -a 256`.
public enum ModelCatalog {
    static let tokenizer = ModelFile(name: "tokenizer.json", size: 19989343,
                                     sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4")
    static let tokenizerConfig = ModelFile(name: "tokenizer_config.json", size: 1139,
                                           sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182")

    public static let qwen4b = ModelSpec(
        choice: .qwen4b, repo: "mlx-community/Qwen3.5-4B-MLX-4bit", revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
        folder: "Qwen3.5-4B-MLX-4bit", files: [
            ModelFile(name: "config.json", size: 3366,
                      sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
            ModelFile(name: "model.safetensors", size: 3034300695,
                      sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
            ModelFile(name: "model.safetensors.index.json", size: 101944,
                      sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
            tokenizer, tokenizerConfig,
            ModelFile(name: "chat_template.jinja", size: 7756,
                      sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
        ])

    public static let qwen2b = ModelSpec(
        choice: .qwen2b, repo: "mlx-community/Qwen3.5-2B-MLX-4bit", revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
        folder: "Qwen3.5-2B-MLX-4bit", files: [
            ModelFile(name: "config.json", size: 3113,
                      sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
            ModelFile(name: "model.safetensors", size: 1722271785,
                      sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
            ModelFile(name: "model.safetensors.index.json", size: 81722,
                      sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
            tokenizer, tokenizerConfig,
            ModelFile(name: "chat_template.jinja", size: 7755,
                      sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
        ])

    public static func spec(_ c: MLXModelChoice) -> ModelSpec {
        switch c {
        case .qwen4b: qwen4b
        case .qwen2b: qwen2b
        }
    }

    /// `$SANKETA_MODEL_DIR` when set, else `~/Library/Application Support/Sanketa/Models`.
    public static func defaultRoot(env: [String: String]) -> URL {
        if let d = env["SANKETA_MODEL_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sanketa/Models", isDirectory: true)
    }

    public static var defaultRoot: URL { defaultRoot(env: ProcessInfo.processInfo.environment) }
}
