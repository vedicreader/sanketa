import Foundation

/// A first pack for a program that has none: the fields that make it show, and one key to copy.
public enum PackStarter {
    /// A file-safe id: `DuckDB CLI` → `duckdb-cli`.
    public static func id(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        let id = String(s).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return id.isEmpty ? "pack" : id
    }

    public static func text(name: String) -> String {
        let q = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        # A Sanketa pack for \(name). Sanketa loads it again when you save it.
        # To check it, run: Sanketa --lint-pack \(id(name)).toml
        id = "\(id(name))"
        name = "\(q)"
        processes = ["\(q)"]

        # Remove the # signs to show this key. Write keys in Mac symbols, such as ⌃D or ⇧⌘P.
        # [[keys]]
        # keys = "⌃D"
        # action = "Quit"
        # group = "Basics"

        """
    }

    /// Writes `<dir>/<id>.toml` if it does not exist, and returns its URL. An existing file stays as it is.
    @discardableResult public static func make(name: String, in dir: URL) throws -> URL {
        let f = dir.appendingPathComponent(id(name) + ".toml")
        guard !FileManager.default.fileExists(atPath: f.path) else { return f }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text(name: name).write(to: f, atomically: true, encoding: .utf8)
        return f
    }
}
