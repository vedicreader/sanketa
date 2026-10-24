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

    /// `printf %s "$NAME"` in a login shell (`shell -l -c`), with a 3 s timeout.
    static func fromShell(varName: String, shell: String, runner: CommandRunning) -> String? {
        nonEmpty(runner.run(shell, ["-l", "-c", "printf %s \"$\(varName)\""], timeout: 3))
    }

    public static func resolve(varName: String, env: [String: String], shell: String?, runner: CommandRunning,
                               store: KeyStore, account: String) -> String? {
        KeyLookup(varName: varName, env: env, shell: shell, runner: runner, store: store, account: account).key()
    }

    /// A typed key, trimmed; nil when empty or when it has spaces or control characters inside.
    public static func clean(_ typed: String) -> String? {
        guard let t = nonEmpty(typed) else { return nil }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return t.unicodeScalars.contains(where: bad.contains) ? nil : t
    }
}

/// `APIKey.resolve` that asks the login shell at most once per launch; the Keychain is read again on each call, so a key
/// typed later is found.
public final class KeyLookup: @unchecked Sendable {
    let varName: String, env: [String: String], shell: String?, runner: CommandRunning, store: KeyStore, account: String
    private let lock = NSLock()
    private var shellAsked = false
    private var shellKey: String?

    public init(varName: String, env: [String: String], shell: String?, runner: CommandRunning, store: KeyStore, account: String) {
        self.varName = varName; self.env = env; self.shell = shell; self.runner = runner; self.store = store; self.account = account
    }

    public func key() -> String? {
        guard APIKey.validName(varName) else { return nil }
        if let k = APIKey.nonEmpty(env[varName]) { return k }
        let fromShell: String? = lock.withLock {
            if !shellAsked, let shell {
                shellKey = APIKey.fromShell(varName: varName, shell: shell, runner: runner)
            }
            shellAsked = true
            return shellKey
        }
        return fromShell ?? APIKey.nonEmpty(store.read(account: account))
    }
}
