import Foundation
@testable import SanketaCore

/// Runs `script` in a real fish (no config) inside `dir`.
@discardableResult
func runFish(_ script: String, in dir: URL) -> String? {
    ProcessRunner().run("/opt/homebrew/bin/fish", ["--no-config", "-c", "cd '\(dir.path)'; \(script)"], timeout: 5)
}

/// Runs `script` in a real bash (no rc files) inside `dir`.
@discardableResult
func runBash(_ script: String, in dir: URL) -> String? {
    ProcessRunner().run("/bin/bash", ["--norc", "--noprofile", "-c", "cd '\(dir.path)'; \(script)"], timeout: 5)
}

func fishQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
}

/// Has real fish write `commands` to a history file in `dir` and returns its URL.
@discardableResult
func writeFishHistory(_ commands: [String], in dir: URL) -> URL {
    let appends = commands.map { "history append \(fishQuote($0))" }.joined(separator: "; ")
    _ = ProcessRunner().run("/usr/bin/env", ["XDG_DATA_HOME=\(dir.path)", "XDG_CONFIG_HOME=\(dir.path)", "/opt/homebrew/bin/fish",
                                             "--no-config", "-c", "set -g fish_history sktest; \(appends); history save"], timeout: 5)
    return dir.appendingPathComponent("fish/sktest_history")
}
