import Foundation
import SanketaCore

/// Finds the API key: the process environment, then the user's login shell, then the Keychain. The key is never logged.
public enum APIKey {
    /// The Keychain account for a server: its host, e.g. `api.openai.com`.
    public static func account(for baseURL: URL) -> String { OpenAIModels.host(baseURL) }

    /// `$SHELL`, else the account's shell; only an absolute path to an executable file.
    public static func loginShell(env: [String: String], passwdShell: String?) -> String? {
        [env["SHELL"], passwdShell].compactMap { $0 }.first(where: isExecutable)
    }

    /// The shell in the user's account record.
    public static func passwdShell() -> String? {
        guard let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell else { return nil }
        return String(cString: sh)
    }

    static func isExecutable(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func validName(_ name: String) -> Bool { name.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static let mark = "\u{1E}"

    /// The `-c` text for the login shell: the value between two record separators, the same in fish, bash, zsh and sh.
    static func shellCommand(_ varName: String) -> String { "printf '\\036%s\\036' \"$\(varName)\"" }

    /// Only the text between the two marks, so banners that rc files print never count as the key.
    static func marked(_ output: String?) -> String? {
        guard let parts = output?.components(separatedBy: mark), parts.count == 3 else { return nil }
        return clean(parts[1])
    }

    /// The variable from a login shell (`shell -l -c`), with a 3 s timeout.
    static func fromShell(varName: String, shell: String, runner: CommandRunning) -> String? {
        marked(runner.run(shell, ["-l", "-c", shellCommand(varName)], timeout: 3))
    }

    /// With no `varName`, only the Keychain item for `account` counts.
    public static func resolve(varName: String?, env: [String: String], shell: String?, runner: CommandRunning,
                               store: KeyStore, account: String) -> String? {
        if let varName {
            guard validName(varName) else { return nil }
            if let k = nonEmpty(env[varName]) { return k }
            if let shell, let k = fromShell(varName: varName, shell: shell, runner: runner) { return k }
        }
        return nonEmpty(store.read(account: account))
    }

    /// A typed key, trimmed; nil when empty or when it has spaces or control characters inside.
    public static func clean(_ typed: String) -> String? {
        guard let t = nonEmpty(typed) else { return nil }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return t.unicodeScalars.contains(where: bad.contains) ? nil : t
    }
}

/// `APIKey.resolve` that asks the login shell at most once per launch; the Keychain is read again on each call, so a key
/// typed later is found. Callers that come while the shell runs wait for the same answer without holding a thread.
/// With no `varName`, it reads only the Keychain item for `account` (the server's host).
public actor KeyLookup {
    public nonisolated let varName: String?
    let env: [String: String], shell: String?, store: KeyStore, account: String
    nonisolated(unsafe) let runner: CommandRunning
    private var shellAnswer: Task<String?, Never>?

    public init(varName: String?, env: [String: String], shell: String?, runner: CommandRunning, store: KeyStore, account: String) {
        self.varName = varName; self.env = env; self.shell = shell; self.runner = runner; self.store = store; self.account = account
    }

    public func key() async -> String? { await lookup()?.key }

    /// The key and where it came from: the environment, the login shell, else the Keychain.
    public func lookup() async -> (key: String, source: KeySource)? {
        if let varName {
            guard APIKey.validName(varName) else { return nil }
            if let k = APIKey.nonEmpty(env[varName]) { return (k, .environment) }
        }
        if let varName, let shell {
            if shellAnswer == nil {
                let (name, runner) = (varName, runner)
                shellAnswer = Task {
                    await withCheckedContinuation { c in
                        DispatchQueue.global().async { c.resume(returning: APIKey.fromShell(varName: name, shell: shell, runner: runner)) }
                    }
                }
            }
            if let k = await shellAnswer?.value { return (k, .shell) }
        }
        return APIKey.nonEmpty(store.read(account: account)).map { ($0, .keychain) }
    }
}
