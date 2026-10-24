import Foundation
import MLX

/// Finds the MLX Metal shader library. Only `make bundle` (xcodebuild) compiles it; `swift build` gives none.
public enum MLXRuntime {
    /// A `.metallib` next to the executable, in `Contents/Resources`, or in a `*Cmlx*.bundle` in either place.
    public static func metallibURL(bundle: Bundle = .main, executable: URL? = Bundle.main.executableURL) -> URL? {
        let dirs = [executable?.deletingLastPathComponent(), bundle.resourceURL].compactMap { $0 }
        for dir in dirs { if let lib = metallib(in: dir) { return lib } }
        for dir in dirs {
            for cmlx in contents(of: dir) where cmlx.pathExtension == "bundle" && cmlx.lastPathComponent.contains("Cmlx") {
                if let res = Bundle(url: cmlx)?.resourceURL, let lib = metallib(in: res) { return lib }
            }
        }
        return nil
    }

    /// True on Apple Silicon when the shaders are present; GPU code checks this first.
    public static var isReady: Bool {
        #if arch(arm64)
        metallibURL() != nil
        #else
        false
        #endif
    }

    /// Adds two small arrays on the GPU; nil when the shaders are missing, so a `swift build` binary does not crash.
    public static func gpuCheck(ready: Bool = isReady) -> Float? {
        guard ready else { return nil }
        return Device.withDefaultDevice(.gpu) { (MLXArray([1, 2] as [Float]) + MLXArray([3, 4] as [Float])).sum().item(Float.self) }
    }

    private static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    private static func metallib(in dir: URL) -> URL? {
        contents(of: dir).sorted { $0.lastPathComponent < $1.lastPathComponent }.first { $0.pathExtension == "metallib" }
    }
}
