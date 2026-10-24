import Foundation

/// A first pack for a program that has none: the fields that make it show, and one key to copy.
public enum PackStarter {
    /// A file-safe id: `DuckDB CLI` → `duckdb-cli`.
    public static func id(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        let id = String(s).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return id.isEmpty ? "pack" : id
    }

    /// What makes the pack show for the layer. A script run by an interpreter (`python3 ~/.local/bin/ramabana`) has the
    /// interpreter as its process, so the pack finds the end of the script path in the command line instead.
    public static func trigger(_ l: Layer) -> (field: String, value: String) {
        if let p = l.process, let script = LayerResolver.script(p, argv: l.argv) {
            return ("match", script.split(separator: "/").suffix(2).joined(separator: "/"))
        }
        return ("processes", l.name)
    }

    public static func text(for l: Layer) -> String {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let t = trigger(l)
        return """
        # A Sanketa pack for \(l.name). Sanketa loads it again when you save it.
        # To check it, run: Sanketa --lint-pack \(id(l.name)).toml
        id = "\(id(l.name))"
        name = "\(q(l.name))"
        \(t.field) = ["\(q(t.value))"]

        # Remove the # signs to show this key. Write keys in Mac symbols, such as ⌃D or ⇧⌘P.
        # [[keys]]
        # keys = "⌃D"
        # action = "Quit"
        # group = "Basics"

        """
    }

    /// Writes `<dir>/<id>.toml` if it does not exist, and returns its URL. An existing file stays as it is.
    @discardableResult public static func make(for l: Layer, in dir: URL) throws -> URL {
        let f = dir.appendingPathComponent(id(l.name) + ".toml")
        guard !FileManager.default.fileExists(atPath: f.path) else { return f }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text(for: l).write(to: f, atomically: true, encoding: .utf8)
        return f
    }
}
