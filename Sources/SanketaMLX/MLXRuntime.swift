import Foundation
import MLX

/// Finds the MLX Metal shader library. Only `make bundle` (xcodebuild) compiles it; `swift build` gives none.
public enum MLXRuntime {
    /// A `.metallib` next to the executable, in `Contents/Resources`, or in a `*Cmlx*.bundle` in either place. In a
    /// test bundle (`.xctest`), also the folder that holds it, where xcodebuild puts the package resource bundles.
    public static func metallibURL(bundle: Bundle = .main, executable: URL? = Bundle.main.executableURL,
                                   code: Bundle = Bundle(for: Marker.self)) -> URL? {
        let tests = code.bundleURL.pathExtension == "xctest" ? code.bundleURL.deletingLastPathComponent() : nil
        let dirs = [executable?.deletingLastPathComponent(), bundle.resourceURL, tests].compactMap { $0 }
        for dir in dirs { if let lib = metallib(in: dir) { return lib } }
        for dir in dirs {
            for cmlx in contents(of: dir) where cmlx.pathExtension == "bundle" && cmlx.lastPathComponent.contains("Cmlx") {
                if let res = Bundle(url: cmlx)?.resourceURL, let lib = metallib(in: res) { return lib }
            }
        }
        return nil
    }

    public final class Marker {}

    /// Tells MLX where the shaders are, for a test bundle where MLX does not find them; true when there are shaders.
    /// GPU code calls this first.
    @discardableResult
    public static func prepare() -> Bool {
        guard isReady, let lib = found else { return false }
        if GPU.metallib == nil { GPU.metallib = lib }
        return true
    }

    /// `metallibURL()`, looked up once: the app's files do not change while it runs, and `status()` runs at each search.
    static let found: URL? = metallibURL()

    /// True on Apple Silicon when the shaders are present; GPU code checks this first.
    public static var isReady: Bool {
        #if arch(arm64)
        found != nil
        #else
        false
        #endif
    }

    /// Adds two small arrays on the GPU; nil when the shaders are missing, so a `swift build` binary does not crash.
    public static func gpuCheck(ready: Bool = isReady) -> Float? {
        guard ready, prepare() else { return nil }
        return Device.withDefaultDevice(.gpu) { (MLXArray([1, 2] as [Float]) + MLXArray([3, 4] as [Float])).sum().item(Float.self) }
    }

    /// MLX's GPU memory in bytes: in use, kept in its buffer cache, and the peak.
    public static var memory: (active: Int, cache: Int, peak: Int) { (Memory.activeMemory, Memory.cacheMemory, Memory.peakMemory) }

    private static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    private static func metallib(in dir: URL) -> URL? {
        contents(of: dir).sorted { $0.lastPathComponent < $1.lastPathComponent }.first { $0.pathExtension == "metallib" }
    }
}
