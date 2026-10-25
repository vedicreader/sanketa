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

/// Records each call and answers with fixed text; runs nothing.
private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { var path: String, args: [String], timeout: TimeInterval }
    private let lock = NSLock()
    private var log: [Call] = []
    let answer: String?
    /// when set, each run waits for the test to open it; the run is on a GCD thread (KeyLookup), not the Swift pool
    let gate: DispatchSemaphore?
    init(answer: String? = nil, gate: DispatchSemaphore? = nil) { self.answer = answer; self.gate = gate }
    var calls: [Call] { lock.withLock { log } }
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        lock.withLock { log.append(Call(path: path, args: args, timeout: timeout)) }
        gate?.wait()
        return answer
    }
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
private let fish = "/opt/homebrew/bin/fish"
private let hasFish = FileManager.default.fileExists(atPath: fish)
private let marked = "\u{1E}sk-shell\u{1E}"

private func resolve(_ varName: String = "OPENAI_API_KEY", env: [String: String] = [:], shell: String?,
                     runner: CommandRunning = RecordingRunner(), store: KeyStore = MemoryKeyStore()) -> String? {
    APIKey.resolve(varName: varName, env: env, shell: shell, runner: runner, store: store, account: openAI)
}

/// A temp HOME whose login files hold the given text; plain files only, nothing executable.
private func home(bashProfile: String? = nil, fishConfig: String? = nil) throws -> URL {
    let h = try keyTempDir()
    if let bashProfile { try bashProfile.write(to: h.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8) }
    if let fishConfig {
        try FileManager.default.createDirectory(at: h.appendingPathComponent("fish"), withIntermediateDirectories: true)
        try fishConfig.write(to: h.appendingPathComponent("fish/config.fish"), atomically: true, encoding: .utf8)
    }
    return h
}

/// The key that real `/bin/bash -l` finds with the given `.bash_profile`, in a clean environment.
private func bashKey(_ profile: String, store: KeyStore = MemoryKeyStore()) throws -> String? {
    resolve(shell: "/bin/bash", runner: CleanEnvRunner(vars: ["HOME": try home(bashProfile: profile).path]), store: store)
}

/// The key that real `fish -l` finds with the given `config.fish`, in a clean environment.
private func fishKey(_ config: String, store: KeyStore = MemoryKeyStore()) throws -> String? {
    let h = try home(fishConfig: config).path
    return resolve(shell: fish, runner: CleanEnvRunner(vars: ["HOME": h, "XDG_CONFIG_HOME": h]), store: store)
}

private func storeWith(_ key: String) throws -> MemoryKeyStore {
    let s = MemoryKeyStore()
    try s.write(key, account: openAI)
    return s
}

private func lookup(_ runner: CommandRunning, store: KeyStore = MemoryKeyStore()) -> KeyLookup {
    KeyLookup(varName: "OPENAI_API_KEY", env: [:], shell: "/bin/bash", runner: runner, store: store, account: openAI)
}

@Suite struct APIKeyTests {
    @Test func keyFromEnvWins() throws {
        let runner = RecordingRunner(answer: marked)
        #expect(resolve(env: ["OPENAI_API_KEY": " sk-env \n"], shell: "/bin/bash", runner: runner, store: try storeWith("sk-store"))
                == "sk-env")
        #expect(runner.calls.isEmpty)
    }

    @Test func loginShellGetsTheVariableName() {
        let runner = RecordingRunner()
        _ = resolve("OPENROUTER_API_KEY", shell: "/bin/bash", runner: runner)
        #expect(runner.calls == [.init(path: "/bin/bash", args: ["-l", "-c", #"printf '\036%s\036' "$OPENROUTER_API_KEY""#],
                                       timeout: 3)])
    }

    @Test func badVarNameRunsNothing() {
        let runner = RecordingRunner(answer: marked)
        for name in ["X; touch /tmp/sanketa-marker", "lower", "1ABC", "", "A-B", "A$B", "A B"] {
            #expect(resolve(name, env: [name: "sk-env"], shell: "/bin/bash", runner: runner) == nil)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func realBashFindsTheKey() throws {
        #expect(try bashKey("export OPENAI_API_KEY=sk-test-bash\n") == "sk-test-bash")
    }

    @Test func realBashBannersAreNotTheKey() throws {
        #expect(try bashKey("echo 'Welcome to the box'\nexport OPENAI_API_KEY=sk-test-bash\necho 'conda: base active'\n")
                == "sk-test-bash")
    }

    @Test func realBashBannerOnlyIsNoKey() throws {
        #expect(try bashKey("echo 'Welcome to the box'\n", store: try storeWith("sk-store")) == "sk-store")
    }

    @Test func realBashEmptyFallsToStore() throws {
        #expect(try bashKey("", store: try storeWith("sk-store")) == "sk-store")
        #expect(try bashKey("") == nil)
    }

    @Test func realBashFailingFallsToStore() throws {
        #expect(try bashKey("export OPENAI_API_KEY=sk-test-bash\nprintf sk-partial; exit 1\n", store: try storeWith("sk-store"))
                == "sk-store")
    }

    @Test func realBashSlowTimesOut() throws {
        let clock = ContinuousClock(), t = clock.now
        #expect(try bashKey("/bin/sleep 10\nexport OPENAI_API_KEY=sk-test-bash\n") == nil)
        #expect(clock.now - t < .milliseconds(4500))
    }

    @Test func realBashKeyWithSpacesIsRejected() throws {
        #expect(try bashKey("export OPENAI_API_KEY='sk test'\n") == nil)
    }

    @Test(.enabled(if: hasFish)) func realFishFindsTheKey() throws {
        #expect(try fishKey("echo 'hello from fish'\nset -gx OPENAI_API_KEY sk-test-fish\necho bye\n") == "sk-test-fish")
    }

    @Test(.enabled(if: hasFish)) func realFishEmptyAndFailing() throws {
        #expect(try fishKey("", store: try storeWith("sk-store")) == "sk-store")
        // in fish, `exit` in config.fish ends only that file, so the command still runs; the marks drop "sk-partial"
        #expect(try fishKey("set -gx OPENAI_API_KEY sk-test-fish\nprintf sk-partial; exit 1\n") == "sk-test-fish")
    }

    @Test(.enabled(if: hasFish)) func realFishSlowTimesOut() throws {
        let clock = ContinuousClock(), t = clock.now
        #expect(try fishKey("/bin/sleep 10\nset -gx OPENAI_API_KEY sk-test-fish\n") == nil)
        #expect(clock.now - t < .milliseconds(4500))
    }

    @Test func keyFromStoreWithoutShell() throws {
        #expect(resolve(shell: nil, store: try storeWith("sk-store")) == "sk-store")
    }

    @Test func markedTakesOnlyTheMarkedText() {
        #expect(APIKey.marked("motd\n\u{1E}sk-1\u{1E}bye\n") == "sk-1")
        for bad in [nil, "", "sk-1", "\u{1E}sk-1", "\u{1E}\u{1E}", "\u{1E}sk 1\u{1E}", "\u{1E}a\u{1E}b\u{1E}c\u{1E}"] {
            #expect(APIKey.marked(bad) == nil)
        }
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

    @Test func lookupAsksTheShellOncePerLaunch() async throws {
        let runner = RecordingRunner(), store = MemoryKeyStore(), l = lookup(runner, store: store)
        #expect(await l.key() == nil)
        #expect(await l.key() == nil)
        #expect(runner.calls.count == 1)
        try store.write("sk-typed", account: openAI)
        #expect(await l.key() == "sk-typed")
        #expect(runner.calls.count == 1)
    }

    @Test func lookupKeepsTheShellKey() async {
        let runner = RecordingRunner(answer: marked), l = lookup(runner)
        #expect(await l.key() == "sk-shell")
        #expect(await l.key() == "sk-shell")
        #expect(runner.calls.count == 1)
    }

    @Test func lookupCallersShareOneShellRun() async {
        let gate = DispatchSemaphore(value: 0)
        let runner = RecordingRunner(answer: marked, gate: gate), l = lookup(runner)
        let keys = await withTaskGroup(of: String?.self) { g in
            for _ in 0..<5 { g.addTask { await l.key() } }
            // the shell run has started and waits; the other callers come while it runs
            for _ in 0..<200 where runner.calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(100))
            gate.signal()
            return await g.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(keys == Array(repeating: "sk-shell", count: 5))
        #expect(runner.calls.count == 1)
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
