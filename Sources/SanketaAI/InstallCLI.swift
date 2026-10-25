import Foundation
import SanketaCore

/// Download progress in whole steps (5 % by default): `next` gives a percent only when it reaches a new step.
public final class ProgressSteps: @unchecked Sendable {
    let step: Int
    private let lock = NSLock()
    private var last = -1

    public init(every step: Int = 5) { self.step = max(1, step) }

    public func next(done: Int64, total: Int64) -> Int? {
        let p = Int(done * 100 / max(total, 1)) / step * step
        return lock.withLock { guard p > last else { return nil }; last = p; return p }
    }
}

/// `Sanketa --install-model [e4b|4b|2b|4b-6bit] [--force]`.
public enum InstallCLI {
    public static let notReady = "This build cannot run on-device models yet. Use --force to download anyway."
    public static let usage = "usage: Sanketa --install-model [e4b|4b|2b|4b-6bit] [--force]"

    /// The line for a Mac below `MLXModelChoice.memoryFloor`.
    public static func notEnoughMemory(_ memory: UInt64) -> String {
        MLXModelChoice.notEnoughMemory + " This Mac has \(memory >> 30) GB. The smallest model needs \(MLXModelChoice.memoryFloor >> 30) GB."
    }

    /// The exit status: 0 when the model is installed, 1 when the download fails, 2 for a wrong size name, or when this
    /// build can't run the model or the Mac has too little memory for it, and `force` is not set. Below
    /// `MLXModelChoice.memoryFloor` it gives 2 also with `force`. Nothing is requested in the cases that give 2.
    /// `chosen` gets the model when it is installed, so that it becomes the user's on-device model.
    public static func run(which: String?, force: Bool, mlxReady: Bool, defaultChoice: MLXModelChoice, installer: ModelInstaller,
                           memory: UInt64 = ProcessInfo.processInfo.physicalMemory, chosen: (MLXModelChoice) -> Void = { _ in },
                           out: @escaping @Sendable (String) -> Void, err: (String) -> Void) async -> Int32 {
        let choice: MLXModelChoice
        switch which {
        case nil: choice = defaultChoice
        case "e4b": choice = .gemma4e4b
        case "4b": choice = .qwen4b
        case "2b": choice = .qwen2b
        case "4b-6bit": choice = .qwen4b6
        default: err(usage); return 2
        }
        guard MLXModelChoice.anyFits(memory: memory) else { err(notEnoughMemory(memory)); return 2 }
        guard mlxReady || force else { err(notReady); return 2 }
        if memory < choice.minMemory && !force {
            err(MLXModelChoice.memoryWarning(choice, memory: memory) + " Use --force to download it anyway.")
            return 2
        }
        let spec = ModelCatalog.spec(choice)
        if installer.isInstalled(spec) { chosen(choice); out("installed \(installer.directory(spec).path)"); return 0 }
        out("downloading \(spec.repo) (\(String(format: "%.1f GB", Double(spec.downloadSize) / 1e9)))")
        let steps = ProgressSteps()
        do {
            try await installer.install(spec) { done, total in
                if let p = steps.next(done: done, total: total) { out("\(p) %  \(done / 1_000_000) MB of \(total / 1_000_000) MB") }
            }
            chosen(choice)
            out("installed \(installer.directory(spec).path)")
            return 0
        } catch {
            err("cannot install \(spec.folder): \((error as? InstallError)?.message ?? error.localizedDescription)")
            return 1
        }
    }
}
