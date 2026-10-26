import Foundation

/// Which vault tools this Mac has. A tool that is missing shows as a disabled menu line, and Sanketa does not use it.
/// The checks look at files only; the abhyasa server answer comes from a probe that keeps it.
public struct VaultTools: Equatable, Sendable {
    /// the vault file exists
    public var vaultFile: Bool
    /// the vault server program is found, or `mcp_url` is set
    public var server: Bool
    /// Abhyasa.app is installed, or the abhyasa server answers
    public var abhyasa: Bool

    public init(vaultFile: Bool, server: Bool, abhyasa: Bool) {
        self.vaultFile = vaultFile; self.server = server; self.abhyasa = abhyasa
    }

    /// The tools for `c`. `abhyasa` tells if the app is installed or the server answered last time.
    public static func detect(_ c: Config, env: [String: String] = ProcessInfo.processInfo.environment,
                              fileExists: (String) -> Bool = FileManager.default.fileExists,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile,
                              abhyasa: () -> Bool) -> VaultTools {
        VaultTools(vaultFile: fileExists(c.vault.resolvedPath(env: env)),
                   server: !c.vault.mcpURL.isEmpty || c.vault.resolvedCommand(exists: isExecutable) != nil,
                   abhyasa: abhyasa())
    }
}
