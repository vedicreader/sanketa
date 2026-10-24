import Testing
import Foundation
@testable import SanketaAI
import SanketaCore

/// A fresh temp folder for one test.
private func keyTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Writes an executable `/bin/sh` script and gives its path.
private func script(_ body: String, in dir: URL? = nil) throws -> String {
    let d = try dir ?? keyTempDir()
    let f = d.appendingPathComponent("shell-\(UUID().uuidString)")
    try ("#!/bin/sh\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f.path
}

/// Runs each command through `/usr/bin/env -i` with only the given variables, so a real login shell reads a temp HOME
/// and never the user's own config or environment.
private struct CleanEnvRunner: CommandRunning {
    var vars: [String: String]
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        ProcessRunner().run("/usr/bin/env", ["-i"] + vars.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + [path] + args,
                            timeout: timeout)
    }
}

private let openAI = "api.openai.com"

private func resolve(_ varName: String = "OPENAI_API_KEY", env: [String: String] = [:], shell: String?,
                     runner: CommandRunning = ProcessRunner(), store: KeyStore = MemoryKeyStore()) -> String? {
    APIKey.resolve(varName: varName, env: env, shell: shell, runner: runner, store: store, account: openAI)
}

// serial: each new script is checked on its first exec, and parallel checks queue past the 3 s shell timeout
@Suite(.serialized) struct APIKeyTests {
    @Test func keyFromEnvWins() throws {
        let store = MemoryKeyStore()
        try store.write("sk-store", account: openAI)
        #expect(resolve(env: ["OPENAI_API_KEY": " sk-env \n"], shell: "/nonexistent/shell", store: store) == "sk-env")
    }

    @Test func keyFromLoginShell() throws {
        #expect(resolve(shell: try script("printf 'sk-from-shell'")) == "sk-from-shell")
    }

    @Test func loginShellGetsTheVariableName() throws {
        let shell = try script(#"for a in "$@"; do last="$a"; done; printf '%s' "$last""#)
        #expect(resolve("OPENROUTER_API_KEY", shell: shell) == #"printf %s "$OPENROUTER_API_KEY""#)
    }

    @Test func realFishLoginShellReadsItsConfig() throws {
        let home = try keyTempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("fish"), withIntermediateDirectories: true)
        try "set -gx OPENAI_API_KEY sk-dummy-fish\n".write(to: home.appendingPathComponent("fish/config.fish"), atomically: true,
                                                         encoding: .utf8)
        let runner = CleanEnvRunner(vars: ["HOME": home.path, "XDG_CONFIG_HOME": home.path])
        #expect(resolve(shell: "/opt/homebrew/bin/fish", runner: runner) == "sk-dummy-fish")
    }

    @Test func realBashLoginShellReadsItsProfile() throws {
        let home = try keyTempDir()
        try "export OPENAI_API_KEY=sk-dummy-bash\n".write(to: home.appendingPathComponent(".bash_profile"), atomically: true,
                                                         encoding: .utf8)
        let runner = CleanEnvRunner(vars: ["HOME": home.path])
        #expect(resolve(shell: "/bin/bash", runner: runner) == "sk-dummy-bash")
    }

    @Test func keyFromStoreWhenShellHasNone() throws {
        let store = MemoryKeyStore()
        try store.write("sk-store", account: openAI)
        #expect(resolve(shell: try script(":"), store: store) == "sk-store")
    }

    @Test func keyFromStoreWithoutShell() throws {
        let store = MemoryKeyStore()
        try store.write("sk-store", account: openAI)
        #expect(resolve(shell: nil, store: store) == "sk-store")
    }

    @Test func keyMissingIsNil() throws {
        #expect(resolve(shell: try script(":")) == nil)
    }

    @Test func badVarNameRunsNothing() throws {
        let dir = try keyTempDir(), marker = dir.appendingPathComponent("ran")
        let shell = try script("touch '\(marker.path)'; printf sk-bad", in: dir)
        for name in ["X; rm -rf /", "lower", "1ABC", "", "A-B", "A$B"] {
            #expect(resolve(name, env: [name: "sk-env"], shell: shell) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func slowShellTimesOut() throws {
        let clock = ContinuousClock(), t = clock.now
        #expect(resolve(shell: try script("/bin/sleep 10")) == nil)
        #expect(clock.now - t < .milliseconds(4500))
    }

    @Test func failingShellFallsToStore() throws {
        let store = MemoryKeyStore()
        try store.write("sk-store", account: openAI)
        #expect(resolve(shell: try script("printf sk-partial; exit 1"), store: store) == "sk-store")
    }

    @Test func loginShellNeedsExecutable() throws {
        #expect(APIKey.loginShell(env: ["SHELL": "/nope"], passwdShell: nil) == nil)
        #expect(APIKey.loginShell(env: ["SHELL": "bin/sh"], passwdShell: nil) == nil)
        #expect(APIKey.loginShell(env: ["SHELL": "/bin/sh"], passwdShell: "/bin/zsh") == "/bin/sh")
        #expect(APIKey.loginShell(env: [:], passwdShell: "/bin/zsh") == "/bin/zsh")
        #expect(APIKey.loginShell(env: ["SHELL": "/nope"], passwdShell: "/bin/zsh") == "/bin/zsh")
        let dir = try keyTempDir(), plain = dir.appendingPathComponent("plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        #expect(APIKey.loginShell(env: ["SHELL": plain.path], passwdShell: nil) == nil)
        #expect(APIKey.loginShell(env: ["SHELL": dir.path], passwdShell: nil) == nil)
    }

    @Test func accountIsTheHost() {
        #expect(APIKey.account(for: URL(string: "https://api.openai.com/v1")!) == "api.openai.com")
        #expect(APIKey.account(for: URL(string: "https://OpenRouter.ai/api/v1")!) == "openrouter.ai")
        #expect(APIKey.account(for: URL(string: "http://localhost:8080/v1")!) == "localhost")
    }

    @Test func cleanRejectsBadInput() {
        #expect(APIKey.clean("  sk-1  ") == "sk-1")
        #expect(APIKey.clean("sk-1\n") == "sk-1")
        for bad in ["", "   ", "sk 1", "sk\n1", "sk\t1", "sk\u{7}1"] { #expect(APIKey.clean(bad) == nil) }
    }

    @Test func memoryStoreRoundTrip() throws {
        let s = MemoryKeyStore()
        #expect(s.read(account: "a") == nil)
        try s.write("k1", account: "a")
        try s.write("other", account: "b")
        #expect(s.read(account: "a") == "k1")
        try s.write("k2", account: "a")
        #expect(s.read(account: "a") == "k2")
        try s.delete(account: "a")
        #expect(s.read(account: "a") == nil)
        #expect(s.read(account: "b") == "other")
        try s.delete(account: "a")
    }

    @Test func lookupAsksTheShellOncePerLaunch() throws {
        let dir = try keyTempDir(), count = dir.appendingPathComponent("count")
        let shell = try script("printf x >> '\(count.path)'", in: dir)
        let store = MemoryKeyStore()
        let lookup = KeyLookup(varName: "OPENAI_API_KEY", env: [:], shell: shell, runner: ProcessRunner(), store: store,
                               account: openAI)
        #expect(lookup.key() == nil)
        #expect(lookup.key() == nil)
        #expect((try? String(contentsOf: count, encoding: .utf8)) == "x")
        try store.write("sk-typed", account: openAI)
        #expect(lookup.key() == "sk-typed")
        #expect((try? String(contentsOf: count, encoding: .utf8)) == "x")
    }

    @Test func lookupKeepsTheShellKey() throws {
        let dir = try keyTempDir(), count = dir.appendingPathComponent("count")
        let shell = try script("printf x >> '\(count.path)'; printf sk-shell", in: dir)
        let lookup = KeyLookup(varName: "OPENAI_API_KEY", env: [:], shell: shell, runner: ProcessRunner(),
                               store: MemoryKeyStore(), account: openAI)
        #expect(lookup.key() == "sk-shell")
        #expect(lookup.key() == "sk-shell")
        #expect((try? String(contentsOf: count, encoding: .utf8)) == "x")
    }

    @Test func keychainErrorShowsStatusOnly() {
        let e = KeychainStore.Failure(status: errSecAuthFailed)
        #expect("\(e)".contains("\(errSecAuthFailed)"))
    }

    /// Writes to the real login keychain under a unique service, and deletes the item after. Set SANKETA_KEYCHAIN_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let s = KeychainStore(service: "dev.sanketa.test.\(UUID().uuidString)"), account = "test.example"
        defer { try? s.delete(account: account) }
        #expect(s.read(account: account) == nil)
        try s.write("sk-test-1", account: account)
        #expect(s.read(account: account) == "sk-test-1")
        try s.write("sk-test-2", account: account)
        #expect(s.read(account: account) == "sk-test-2")
        try s.delete(account: account)
        #expect(s.read(account: account) == nil)
        try s.delete(account: account)
    }
}
