import Foundation

public struct Word: Hashable, Sendable {
    public var raw: String
    public var value: String
    public var globbed: Bool

    public init(raw: String, value: String, globbed: Bool = false) { self.raw = raw; self.value = value; self.globbed = globbed }

    /// `<`, `>`, `>>`, `2>&1` and the like.
    public var isRedirect: Bool {
        raw.range(of: #"^[0-9&]*(<|>|>>|>&\d*|<&\d*)$"#, options: .regularExpression) != nil
            || raw.range(of: #"^[0-9]*>&[0-9]+$"#, options: .regularExpression) != nil
    }
}

public enum Substitution: Hashable, Sendable { case paren, dollar, backtick }

public struct ShellCommand: Hashable, Sendable {
    public var text: String
    public var stages: [[Word]]
    public var substitution: Substitution?
    public var wrappedText: String?

    public init(text: String, stages: [[Word]], substitution: Substitution? = nil, wrappedText: String? = nil) {
        self.text = text; self.stages = stages; self.substitution = substitution; self.wrappedText = wrappedText
    }
}

public enum ShellLex {
    /// The pipelines of `line`, each followed by the commands of its substitutions. An unbalanced quote,
    /// parenthesis or backtick gives `[]`.
    public static func commands(_ line: String, shell: Shell) -> [ShellCommand] {
        Lexer(Array(line.replacingOccurrences(of: "\r\n", with: "\n")), shell).lex() ?? []
    }

    static let keywords: [Shell: Set<String>] = [.fish: ["and", "or", "not", "time", "command", "builtin"],
                                                 .bash: ["time", "!", "do", "then", "else", "elif"]]
}

private struct Lexer {
    let c: [Character]
    let shell: Shell

    init(_ c: [Character], _ shell: Shell) { self.c = c; self.shell = shell }

    func slice(_ r: ClosedRange<Int>) -> String { String(c[r]) }

    /// Index of the `)` that closes the `(` at `open`, skipping quoted text and escapes.
    func closingParen(_ open: Int) -> Int? {
        var depth = 0, i = open
        while i < c.count {
            switch c[i] {
            case "(": depth += 1
            case ")": depth -= 1; if depth == 0 { return i }
            case "\\": i += 1
            case "'", "\"":
                let q = c[i]; i += 1
                while i < c.count, c[i] != q {
                    if c[i] == "\\" && (q == "\"" || shell == .fish) { i += 1 }
                    i += 1
                }
                if i >= c.count { return nil }
            default: break
            }
            i += 1
        }
        return nil
    }

    func closingBacktick(_ open: Int) -> Int? {
        var i = open + 1
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "`" { return i }
            i += 1
        }
        return nil
    }

    /// The substitution that starts at `i` (`(`, `$(` or a backtick): its commands, the end index and its kind.
    func substitution(at i: Int) -> (cmds: [ShellCommand], end: Int, kind: Substitution)? {
        let dollar = c[i] == "$", backtick = c[i] == "`"
        let open = dollar ? i + 1 : i
        guard let end = backtick ? closingBacktick(open) : closingParen(open) else { return nil }
        let kind: Substitution = backtick ? .backtick : dollar ? .dollar : .paren
        let wrapped = slice(i...end)
        // bash `$(( … ))` is arithmetic, not a command
        if dollar, shell == .bash, open + 1 < c.count, c[open + 1] == "(" { return ([], end, kind) }
        guard let inner = Lexer(Array(c[(open + 1)..<end]), shell).lex() else { return nil }
        return (inner.map { var x = $0; if x.substitution == nil { x.substitution = kind; x.wrappedText = wrapped }; return x }, end, kind)
    }

    func lex() -> [ShellCommand]? {
        var out: [ShellCommand] = [], subs: [ShellCommand] = []
        var stages: [[Word]] = [], words: [Word] = []
        var raw = "", val = "", glob = false, inWord = false
        var start = 0, i = 0

        func endWord() {
            if inWord { words.append(Word(raw: raw, value: val, globbed: glob)) }
            raw = ""; val = ""; glob = false; inWord = false
        }
        func endStage() { endWord(); if !words.isEmpty { stages.append(words) }; words = [] }
        func endCommand(_ end: Int) {
            endStage()
            let kw = ShellLex.keywords[shell] ?? []
            while !stages.isEmpty, let w = stages[0].first, w.raw == w.value, kw.contains(w.raw) {
                stages[0].removeFirst()
                if stages[0].isEmpty { stages.removeFirst() }
            }
            if !stages.isEmpty {
                let text = String(c[start..<max(start, end)]).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(ShellCommand(text: text, stages: stages)); out += subs
            }
            stages = []; subs = []
        }
        func take(_ r: ClosedRange<Int>) { let s = slice(r); raw += s; val += s; inWord = true }

        while i < c.count {
            let ch = c[i], next: Character? = i + 1 < c.count ? c[i + 1] : nil
            switch ch {
            case " ", "\t": endWord(); i += 1
            case "\n": endCommand(i); i += 1; start = i
            case ";": endCommand(i); i += 1; start = i
            case "\\":
                if next == "\n" { endWord(); i += 2 }
                else if let n = next { raw += "\\\(n)"; val.append(n); inWord = true; i += 2 }
                else { raw += "\\"; val += "\\"; inWord = true; i += 1 }
            case "'":
                var j = i + 1, v = ""
                while true {
                    guard j < c.count else { return nil }
                    if c[j] == "'" { break }
                    if shell == .fish, c[j] == "\\", j + 1 < c.count, c[j + 1] == "'" || c[j + 1] == "\\" { v.append(c[j + 1]); j += 2; continue }
                    v.append(c[j]); j += 1
                }
                raw += slice(i...j); val += v; inWord = true; i = j + 1
            case "\"":
                var j = i + 1, v = ""
                while true {
                    guard j < c.count else { return nil }
                    if c[j] == "\"" { break }
                    if c[j] == "\\", j + 1 < c.count, "\"\\$".contains(c[j + 1]) || (shell == .bash && c[j + 1] == "`") {
                        v.append(c[j + 1]); j += 2; continue
                    }
                    if (c[j] == "$" && j + 1 < c.count && c[j + 1] == "(") || (c[j] == "`" && shell == .bash) {
                        guard let s = substitution(at: j) else { return nil }
                        subs += s.cmds; v += slice(j...s.end); j = s.end + 1; continue
                    }
                    v.append(c[j]); j += 1
                }
                raw += slice(i...j); val += v; inWord = true; i = j + 1
            case "$" where next == "(":
                guard let s = substitution(at: i) else { return nil }
                subs += s.cmds; take(i...s.end); i = s.end + 1
            case "(" where shell == .fish:
                guard let s = substitution(at: i) else { return nil }
                subs += s.cmds; take(i...s.end); i = s.end + 1
            case ")" where shell == .fish: return nil
            case "`" where shell == .bash:
                guard let s = substitution(at: i) else { return nil }
                subs += s.cmds; take(i...s.end); i = s.end + 1
            case "#" where !inWord:
                endWord()
                var j = i
                while j < c.count, c[j] != "\n" { j += 1 }
                endCommand(i); i = j; start = j
            case "&":
                if next == "&" { endCommand(i); i += 2; start = i }
                else if shell == .fish, next == "|" { endStage(); i += 2 }
                else if next == ">" || (inWord && (raw.hasSuffix(">") || raw.hasSuffix("<"))) { raw.append(ch); val.append(ch); inWord = true; i += 1 }
                else { endCommand(i); i += 1; start = i }
            case "|":
                if next == "|" { endCommand(i); i += 2; start = i }
                else { endStage(); i += next == "&" ? 2 : 1 }
            default:
                if ch == "*" || ch == "[" || (ch == "?" && raw.last != "$") { glob = true }
                raw.append(ch); val.append(ch); inWord = true; i += 1
            }
        }
        endCommand(c.count)
        return out
    }
}
