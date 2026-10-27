import Foundation

/// The kind of an AeroSpace command; the order is the column order of the combo view.
public enum AeroKind: Int, Comparable, Sendable {
    case moveTile, focus, workspace, sendToWorkspace, layout, monitor, mode, script, resize, other
    public static func < (a: AeroKind, b: AeroKind) -> Bool { a.rawValue < b.rawValue }
}

/// One key binding of an AeroSpace mode; `line` is the 1-based line of its key.
public struct AeroBinding: Hashable, Sendable {
    public var chord: Chord
    public var commands: [String]
    public var line: Int
    public var action: String
    public var kind: AeroKind
    public var target: String?
}

/// The `[mode.NAME.binding]` tables of an AeroSpace config, read line by line so each binding keeps its line number.
public struct AeroSpaceConfig: Sendable {
    public var modes: [String: [AeroBinding]]

    public static func parse(_ text: String) -> AeroSpaceConfig {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var modes = [String: [AeroBinding]](), mode: String?, i = 0
        while i < lines.count {
            let first = i, line = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.hasPrefix("[") {
                let head = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                mode = head.hasPrefix("[mode.") && head.hasSuffix(".binding]") ? String(head.dropFirst(6).dropLast(9)) : nil
                if let mode { modes[mode, default: []] += [] }
                continue
            }
            guard let mode, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let commands = values(lines, &i, line[line.index(after: eq)...])
            guard let chord = Chord.aerospace(name), !commands.isEmpty else { continue }
            let d = describe(commands)
            modes[mode, default: []].append(AeroBinding(chord: chord, commands: commands, line: first + 1, action: d.action, kind: d.kind, target: d.target))
        }
        return AeroSpaceConfig(modes: modes)
    }

    /// The strings of one TOML value (a string or an array of strings); `i` moves past any extra lines it uses.
    static func values(_ lines: [Substring], _ i: inout Int, _ rest: Substring) -> [String] {
        var cur = Array(rest), p = 0, out = [String](), inArray = false
        while true {
            while p < cur.count, cur[p] == " " || cur[p] == "\t" || cur[p] == "," { p += 1 }
            if p >= cur.count || cur[p] == "#" {
                guard inArray, i < lines.count else { break }
                cur = Array(lines[i]); p = 0; i += 1
                continue
            }
            let c = cur[p]
            if c == "[" || c == "]" { inArray = c == "["; p += 1; if c == "]" { break } else { continue } }
            guard c == "'" || c == "\"" else { break }
            let triple = p + 2 < cur.count && cur[p + 1] == c && cur[p + 2] == c
            var s = "", closed = false
            p += triple ? 3 : 1
            if triple, p >= cur.count, i < lines.count { cur = Array(lines[i]); p = 0; i += 1 }   // a newline right after the opener is dropped
            while !closed {
                if p >= cur.count {
                    guard triple, i < lines.count else { break }
                    s += "\n"; cur = Array(lines[i]); p = 0; i += 1
                } else if cur[p] == c, !triple || (p + 2 < cur.count && cur[p + 1] == c && cur[p + 2] == c) {
                    closed = true; p += triple ? 3 : 1
                } else if c == "\"", cur[p] == "\\", p + 1 < cur.count {
                    s.append(cur[p + 1]); p += 2
                } else { s.append(cur[p]); p += 1 }
            }
            out.append(s)
            if !inArray { break }
        }
        return out
    }

    /// Plain words for the first command, with its kind and its workspace or direction.
    public static func describe(_ commands: [String]) -> (action: String, kind: AeroKind, target: String?) {
        let cmd = commands.first ?? ""
        let w = cmd.split(whereSeparator: \.isWhitespace).map(String.init), args = Array(w.dropFirst())
        let last = args.last, prev = last == "prev"
        switch w.first {
        case "move": if let d = last { return ("Move the tile \(d)", .moveTile, d) }
        case "focus":
            if let d = last { return d == "dfs-next" ? ("Focus next", .focus, nil) : d == "dfs-prev" ? ("Focus previous", .focus, nil) : ("Focus \(d)", .focus, d) }
        case "workspace":
            if args.contains("--wrap-around") { return (prev ? "Previous workspace" : "Next workspace", .workspace, nil) }
            if let n = last { return ("Go to workspace \(n)", .workspace, n) }
        case "workspace-back-and-forth": return ("Last workspace", .workspace, nil)
        case "move-node-to-workspace":
            if args.contains("--wrap-around") { return ("Send the tile to the \(prev ? "previous" : "next") workspace", .sendToWorkspace, nil) }
            if let n = last { return ("Send the tile to \(n)" + (args.contains("--focus-follows-window") ? " and follow" : ""), .sendToWorkspace, n) }
        case "fullscreen": return ("Full screen", .layout, nil)
        case "layout":
            let names = ["floating tiling": "Float or tile", "accordion tiles": "Accordion or tiles", "horizontal vertical": "Side by side or stacked"]
            if let a = names[args.joined(separator: " ")] { return (a, .layout, nil) }
        case "focus-monitor": return ("Focus the \(prev || args.contains("left") ? "previous" : "next") monitor", .monitor, nil)
        case "mode": if let n = last { return (n == "main" ? "Back to normal" : "\(n) mode", .mode, n) }
        case "exec-and-forget": return ("Run a script", .script, nil)
        case "resize": return (last?.hasPrefix("-") == true ? "Make it smaller" : "Make it bigger", .resize, nil)
        case "balance-sizes": return ("Balance sizes", .resize, nil)
        default: break
        }
        return (cmd, .other, nil)
    }

    /// The config file: `~/.aerospace.toml`, else `$XDG_CONFIG_HOME/aerospace/aerospace.toml` (or `~/.config/...`); nil when none exists.
    public static func url(env: [String: String], home: URL, fileExists: (String) -> Bool) -> URL? {
        urls(env: env, home: home).first { fileExists($0.path) }
    }

    /// The places where the config file can be, in order; a watcher on each finds a file that is made later.
    public static func urls(env: [String: String], home: URL) -> [URL] {
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return [home.appendingPathComponent(".aerospace.toml"), xdg.appendingPathComponent("aerospace/aerospace.toml")]
    }
}
