import Foundation

public struct Rewrite: Hashable, Sendable {
    public var before: String
    public var after: String
    public var explain: String
    public init(before: String, after: String, explain: String) { self.before = before; self.after = after; self.explain = explain }
}

public struct Detector: Sendable {
    public var id: String
    public var title: String
    public var shells: Set<Shell>
    public var rewrite: @Sendable (ShellCommand, Shell) -> Rewrite?
}

/// Rules that find a shorter or safer way to write a command. Each rule gives a rewrite only when it does the same
/// thing; on any doubt it gives nil.
public enum Detectors {
    public static let all: [Detector] = [
        Detector(id: "pgrep", title: "Find processes with pgrep", shells: [.fish, .bash], rewrite: pgrep),
        Detector(id: "grep-count", title: "Count matches with grep -c", shells: [.fish, .bash], rewrite: grepCount),
        Detector(id: "grep-awk", title: "Let awk match the pattern", shells: [.fish, .bash], rewrite: grepAwk),
        Detector(id: "sort-unique", title: "Drop duplicates with sort -u", shells: [.fish, .bash], rewrite: sortUnique),
        Detector(id: "find-xargs", title: "Run a command on found files", shells: [.fish, .bash], rewrite: findXargs),
        Detector(id: "find-glob", title: "Find files with a glob", shells: [.fish], rewrite: findGlob),
        Detector(id: "ls-grep", title: "Pick names with a glob", shells: [.fish, .bash], rewrite: lsGrep),
        Detector(id: "glob-loop", title: "Loop over a glob, not ls", shells: [.fish], rewrite: globLoop),
        Detector(id: "math", title: "Do arithmetic in the shell", shells: [.fish, .bash], rewrite: math),
        Detector(id: "string-split", title: "Split text with string split", shells: [.fish], rewrite: stringSplit),
        Detector(id: "string-replace", title: "Replace text with string replace", shells: [.fish], rewrite: stringReplace),
        Detector(id: "string-case", title: "Change case with string upper", shells: [.fish], rewrite: stringCase),
        Detector(id: "useless-cat", title: "Give the file to the command", shells: [.fish, .bash], rewrite: uselessCat),
    ]

    // MARK: - Rules

    static func pgrep(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard (2...3).contains(st.count), st[0].count == 2, name(st[0]) == "ps", ["aux", "-ef", "-e", "ax"].contains(st[0][1].raw) else { return nil }
        var target: String?, skips = 0
        for s in st.dropFirst() {
            if s.map(\.raw) == ["grep", "-v", "grep"] { skips += 1; continue }
            guard target == nil, s.count == 2, name(s) == "grep", !s[1].isFlag, matches(s[1].value, #"^[A-Za-z0-9._-]+$"#) else { return nil }
            target = s[1].value
        }
        guard let t = target, skips <= 1 else { return nil }
        return Rewrite(before: c.text, after: "pgrep -fl \(t)", explain: "pgrep -f matches full command lines and never lists itself. ps aux cuts long lines, so the results can differ.")
    }

    static func grepCount(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard st.count >= 2, st[st.count - 1].map(\.raw) == ["wc", "-l"] else { return nil }
        let i = st.count - 2, g = st[i]
        guard name(g) == "grep", let a = split(g.dropFirst(), Opts(noArg: "ivwxEFns")), (1...2).contains(a.operands.count),
              a.operands.dropFirst().allSatisfy(\.isPlainFile) else { return nil }
        var head = Array(st[..<i]), args = Array(g.dropFirst())
        if i == 1, a.operands.count == 1, let f = catFile(st) { head = []; args.append(f) }
        return Rewrite(before: c.text, after: join(head + [[Word(raw: "grep", value: "grep"), Word(raw: "-c", value: "-c")] + args]),
                       explain: "grep -c counts matching lines itself. It exits with status 1 when no line matches.")
    }

    static func grepAwk(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        for i in st.indices.dropLast() {
            let g = st[i], k = st[i + 1]
            guard name(g) == "grep", (2...3).contains(g.count), g.dropFirst().allSatisfy({ !$0.isFlag }),
                  matches(g[1].value, #"^[A-Za-z0-9_ :=-]+$"#), g.count == 2 || g[2].isPlainFile,
                  name(k) == "awk", let a = split(k.dropFirst(), Opts(withArg: "F")), a.operands.count == 1,
                  let prog = a.operands.first?.value, isSingleAction(prog) else { continue }
            var head = Array(st[..<i]), file = g.count == 3 ? g[2] : nil
            if file == nil, i == 1, let f = catFile(st) { head = []; file = f }
            let body = Word(raw: "'/\(g[1].value)/ \(prog)'", value: "")
            let awk = [k[0]] + a.opts + [body] + (file.map { [$0] } ?? [])
            return Rewrite(before: c.text, after: join(head + [awk] + st[(i + 2)...]),
                           explain: "awk can match the pattern and print the field in one pass.")
        }
        return nil
    }

    static func sortUnique(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        for i in st.indices.dropLast() where name(st[i]) == "sort" && st[i + 1].map(\.raw) == ["uniq"] {
            let args = st[i].dropFirst()
            let reverse = args.filter { $0.raw == "-r" }, files = args.filter { $0.raw != "-r" }
            guard reverse.count <= 1, files.allSatisfy(\.isPlainFile) else { return nil }
            var head = Array(st[..<i]), ops = Array(files)
            if i == 1, ops.isEmpty, let f = catFile(st) { head = []; ops = [f] }
            let sort = [st[i][0]] + reverse + [Word(raw: "-u", value: "-u")] + ops
            return Rewrite(before: c.text, after: join(head + [sort] + st[(i + 2)...]), explain: "sort -u drops duplicate lines while sorting.")
        }
        return nil
    }

    static func findXargs(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard st.count == 2, let f = findParts(st[0]), name(st[1]) == "xargs", st[1].count >= 2, !st[1][1].isFlag, name(Array(st[1].dropFirst())) != nil,
              st[1].allSatisfy({ $0.value != "{}" }) else { return nil }
        let cmd = emit(st[1].dropFirst())
        if sh == .fish {
            guard let glob = f.glob else { return nil }
            return Rewrite(before: c.text, after: "\(cmd) \(glob)", explain: "** expands to the matching files; names with spaces stay intact.")
        }
        return Rewrite(before: c.text, after: "\(emit(st[0])) -exec \(cmd) {} +", explain: "-exec … {} + gives many files to one command, as xargs does. Names with spaces work.")
    }

    static func findGlob(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        guard sh == .fish, c.stages.count == 1, let glob = findParts(c.stages[0])?.glob else { return nil }
        return Rewrite(before: c.text, after: "printf '%s\\n' \(glob)", explain: "fish's ** goes into subfolders and skips hidden ones, as -not -path '*/.*' does.")
    }

    static func lsGrep(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard st.count >= 2, [["ls"], ["ls", "-1"]].contains(st[0].map(\.raw)), st[1].count == 2, name(st[1]) == "grep", !st[1][1].isFlag
        else { return nil }
        let p = st[1][1].value
        let glob: String
        if matches(p, #"^[A-Za-z0-9_-]+$"#) { glob = "*\(p)*" }
        // only an escaped dot: an unescaped `.` also matches `xtxt`, which `*.txt` does not
        else if matches(p, #"^\\\.[A-Za-z0-9]+\$$"#) { glob = "*." + p.dropFirst(2).dropLast() }
        else { return nil }
        let ls = [Word(raw: "ls", value: "ls"), Word(raw: "-d", value: "-d"), Word(raw: glob, value: glob, globbed: true)]
        return Rewrite(before: c.text, after: join([ls] + st[2...]), explain: "A glob picks the names directly.")
    }

    static func globLoop(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        // bash keeps a glob that matches nothing as literal text, so the loop would run once; fish runs it zero times
        guard sh == .fish, c.stages.count == 1 else { return nil }
        let s = c.stages[0]
        guard s.count == 4, s[0].raw == "for", matches(s[1].raw, #"^[A-Za-z_][A-Za-z0-9_]*$"#), s[2].raw == "in",
              s[3].raw.hasPrefix("("), s[3].raw.hasSuffix(")") else { return nil }
        let cs = ShellLex.commands(String(s[3].raw.dropFirst().dropLast()), shell: sh)
        guard cs.count == 1, cs[0].stages.count == 1, name(cs[0].stages[0]) == "ls" else { return nil }
        let args = cs[0].stages[0].dropFirst()
        guard args.allSatisfy({ $0.globbed && !$0.isFlag && !$0.raw.contains(where: { "$`(){}".contains($0) }) }) else { return nil }
        return Rewrite(before: c.text, after: "for \(s[1].raw) in \(args.isEmpty ? "*" : emit(args))",
                       explain: "Loop over the glob. The output of ls breaks on spaces. If a folder matches, ls lists what is in it, but the glob gives the folder name.")
    }

    /// Operands and operators that expr, math, bc and `$(( ))` all compute the same way: literal whole numbers without a
    /// leading zero (bash reads `010` as octal), `/` or `%` only as the single operation (math -s0 and bc cut only
    /// the final result), and with `*` at most 15 digits in total (math and bc lose whole numbers above 2^53).
    /// No variables: bash fails on a value like `08`, and math and `$(( ))` give 1 for `$e + 1` with `e` empty, where expr fails.
    static func isSafeArithmetic(_ t: [String]) -> Bool {
        guard t.count >= 3, t.count % 2 == 1 else { return false }
        let operands = stride(from: 0, to: t.count, by: 2).map { t[$0] }, ops = stride(from: 1, to: t.count, by: 2).map { t[$0] }
        guard operands.allSatisfy({ matches($0, #"^(0|[1-9][0-9]{0,8})$"#) }),
              ops.allSatisfy({ ["+", "-", "*", "/", "%"].contains($0) }) else { return false }
        if (ops.contains("/") || ops.contains("%")) && ops.count > 1 { return false }
        return !ops.contains("*") || operands.reduce(0, { $0 + $1.count }) <= 15
    }

    static func math(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        let status = " expr exits with status 1 when the result is 0, but this does not."
        let fishNote = "fish's math builtin; -s0 keeps integer division.", bashNote = "Shell arithmetic, no extra process."
        if st.count == 1, name(st[0]) == "expr" {
            let args = Array(st[0].dropFirst())
            guard args.allSatisfy({ !$0.globbed }), args.enumerated().allSatisfy({ $0.offset % 2 == 1 || $0.element.raw == $0.element.value }),
                  isSafeArithmetic(args.map(\.value)) else { return nil }
            let ops = stride(from: 1, to: args.count, by: 2).map { args[$0].value }
            if sh == .bash {
                let expr = args.enumerated().map { $0.offset % 2 == 0 ? $0.element.raw : $0.element.value }.joined(separator: " ")
                if c.substitution != nil, let w = c.wrappedText { return Rewrite(before: w, after: "$(( \(expr) ))", explain: bashNote + status) }
                return Rewrite(before: c.text, after: "echo $(( \(expr) ))", explain: bashNote + status)
            }
            let scale = ops.contains("/") || ops.contains("%") ? "-s0 " : ""
            // `*` would glob unquoted; isSafeArithmetic allows no variable, so single quotes are safe
            let expr = ops.contains("*") ? "'\(args.map(\.value).joined(separator: " "))'" : emit(args)
            return Rewrite(before: c.text, after: "math \(scale)\(expr)", explain: fishNote + status)
        }
        guard sh == .fish, st.count == 2, st[0].count == 2, name(st[0]) == "echo", st[1].map(\.raw) == ["bc"],
              matches(st[0][1].value, #"^ *[0-9]+( *[-+*/%] *[0-9]+)+ *$"#) else { return nil }
        let e = st[0][1].value
        var tokens: [String] = []
        for ch in e where ch != " " {
            if ch.isNumber, let last = tokens.last, last.allSatisfy(\.isNumber) { tokens[tokens.count - 1].append(ch) } else { tokens.append(String(ch)) }
        }
        guard isSafeArithmetic(tokens) else { return nil }
        let scale = e.contains("/") || e.contains("%") ? "-s0 " : ""
        return Rewrite(before: c.text, after: "math \(scale)'\(e)'", explain: fishNote)
    }

    /// `"$VAR"`: a list variable stays one argument, as `echo` joins it into one line.
    static func quoted(_ v: Word) -> String { "\"\(v.value)\"" }

    static func stringSplit(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard sh == .fish, st.count == 2, let v = echoVariable(st[0]), name(st[1]) == "cut" else { return nil }
        var delim: String?, field: String?, i = 1
        let ws = st[1]
        while i < ws.count {
            let w = ws[i].value
            func value() -> String? {
                if w.count > 2 { return String(w.dropFirst(2)) }
                i += 1
                return i < ws.count ? ws[i].value : nil
            }
            if w.hasPrefix("-d"), delim == nil { delim = value() }
            else if w.hasPrefix("-f"), field == nil { field = value() }
            else { return nil }
            i += 1
        }
        // only field 1: on a line without the delimiter, cut prints the whole line and string split -fN (N > 1) prints nothing
        guard let d = delim, d.count == 1, field == "1", d != "-", d != "'", d != "\\" else { return nil }
        let shown = matches(d, #"^[A-Za-z0-9,:._=/@+%]$"#) ? d : "'\(d)'"
        return Rewrite(before: c.text, after: "string split -f1 \(shown) -- \(quoted(v))", explain: "fish's string split -f1 picks the first field. It exits with status 1 when the text has no delimiter. A value that starts with - (like -n) is an option to echo, so the old command can print something else.")
    }

    static func stringReplace(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard sh == .fish, st.count == 2, let v = echoVariable(st[0]), st[1].count == 2, name(st[1]) == "sed" else { return nil }
        let script = st[1][1].value
        guard script.hasPrefix("s/") else { return nil }
        let parts = script.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let cls = #"^[A-Za-z0-9_:@,=+]+$"#
        guard parts.count == 3, ["", "g"].contains(parts[2]), matches(parts[0], cls), parts[1].isEmpty || matches(parts[1], cls) else { return nil }
        let all = parts[2] == "g" ? "-a " : ""
        return Rewrite(before: c.text, after: "string replace \(all)\(parts[0]) \(parts[1].isEmpty ? "''" : parts[1]) \(quoted(v))",
                       explain: "fish's string replace works on variables directly. A value that starts with - (like -n) is an option to echo, so the old command can print something else.")
    }

    static func stringCase(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard sh == .fish, st.count == 2, let v = echoVariable(st[0]), st[1].count == 3, name(st[1]) == "tr",
              !st[1][1].globbed, !st[1][2].globbed else { return nil }
        let lower = ["a-z", "[:lower:]"], upper = ["A-Z", "[:upper:]"], a = st[1][1].value, b = st[1][2].value
        let fn: String
        if lower.contains(a), upper.contains(b) { fn = "upper" }
        else if upper.contains(a), lower.contains(b) { fn = "lower" }
        else { return nil }
        return Rewrite(before: c.text, after: "string \(fn) \(quoted(v))", explain: "fish's string upper/lower. It also changes non-ASCII letters. A value that starts with - (like -n) is an option to echo, so the old command can print something else.")
    }

    static func uselessCat(_ c: ShellCommand, _ sh: Shell) -> Rewrite? {
        let st = c.stages
        guard let f = catFile(st), let cmd = name(st[1]) else { return nil }
        let rest = st[1].dropFirst()
        let operands: (Opts, ClosedRange<Int>, Bool)
        switch cmd {
        case "grep": operands = (Opts(noArg: "ivwxEFnsoc"), 1...1, false)
        case "awk": operands = (Opts(withArg: "F"), 1...1, false)
        case "sed": operands = (Opts(noArg: "nE"), 1...1, false)
        case "head", "tail": operands = (Opts(withArg: "nc", numbers: true), 0...0, false)
        case "sort": operands = (Opts(noArg: "rnfubd"), 0...0, false)
        case "cut": operands = (Opts(noArg: "s", withArg: "dfcb"), 0...0, false)
        case "wc": operands = (Opts(noArg: "lwcm"), 0...0, true)
        case "tr": operands = (Opts(noArg: "dscC"), 1...2, true)
        default: return nil
        }
        guard let a = split(rest, operands.0), operands.1.contains(a.operands.count) else { return nil }
        if cmd == "awk", a.operands[0].value.contains("FILENAME") { return nil }
        let next = st[1] + (operands.2 ? [Word(raw: "<", value: "<")] : []) + [f]
        return Rewrite(before: c.text, after: join([next] + st[2...]), explain: "Give the file to the command directly.")
    }

    // MARK: - Helpers

    struct Opts {
        var noArg: Set<Character> = []
        var withArg: Set<Character> = []
        var numbers = false
        init(noArg: String = "", withArg: String = "", numbers: Bool = false) { self.noArg = Set(noArg); self.withArg = Set(withArg); self.numbers = numbers }
    }

    /// Options (with their values) and operands. nil on an unknown option, a long option, `--` or an option after an operand.
    static func split(_ words: ArraySlice<Word>, _ o: Opts) -> (opts: [Word], operands: [Word])? {
        var opts: [Word] = [], operands: [Word] = [], it = words.makeIterator()
        while let w = it.next() {
            guard w.isFlag else { operands.append(w); continue }
            guard operands.isEmpty, !w.value.hasPrefix("--") else { return nil }
            opts.append(w)
            let letters = Array(w.value.dropFirst())
            if o.numbers, letters.allSatisfy(\.isASCII), letters.allSatisfy(\.isNumber) { continue }
            for (n, l) in letters.enumerated() {
                if o.noArg.contains(l) { continue }
                guard o.withArg.contains(l) else { return nil }
                if n == letters.count - 1 { guard let v = it.next() else { return nil }; opts.append(v) }
                break
            }
        }
        return (opts, operands)
    }

    /// The command name of a stage, when it is a plain unquoted word.
    static func name(_ s: [Word]) -> String? {
        guard let w = s.first, w.raw == w.value, matches(w.raw, #"^[A-Za-z0-9._/-]+$"#) else { return nil }
        return w.raw
    }

    /// The file of a first stage that is exactly `cat F`, when another stage follows.
    static func catFile(_ st: [[Word]]) -> Word? {
        guard st.count > 1, st[0].count == 2, name(st[0]) == "cat", st[0][1].isPlainFile else { return nil }
        return st[0][1]
    }

    /// The word of a stage that is exactly `echo $VAR` or `echo "$VAR"`.
    static func echoVariable(_ s: [Word]) -> Word? {
        guard s.count == 2, name(s) == "echo", isVariable(s[1].value), s[1].raw == s[1].value || s[1].raw == "\"\(s[1].value)\"" else { return nil }
        return s[1]
    }

    static func isVariable(_ s: String) -> Bool { matches(s, #"^\$[A-Za-z_][A-Za-z0-9_]*$"#) }

    /// `find DIR [-type f] -name '*SUFFIX' [-not -path '*/.*']` (the parts in any order; `!` for `-not`), and the fish
    /// glob that names the same entries. `**` skips hidden files and folders, so the glob is nil unless the find also
    /// skips them with `-not -path '*/.*'` (`-not -name '.*'` is not enough: find still looks inside hidden folders).
    /// It is also nil for `-type f` (fish has no glob for files only), a hidden folder in DIR, or a name that is not `*.ext`.
    static func findParts(_ s: [Word]) -> (dir: Word, glob: String?)? {
        guard name(s) == "find", s.count >= 4 else { return nil }
        let dir = s[1]
        guard dir.raw == dir.value, matches(dir.raw, #"^[A-Za-z0-9._~/-]+$"#), !dir.isFlag else { return nil }
        var pat: Word?, typeF = false, noHidden = false, i = 2
        while i < s.count {
            let r = s[i].raw, rest = s.count - i
            if r == "-name", rest >= 2, pat == nil { pat = s[i + 1]; i += 2 }
            else if r == "-type", rest >= 2, s[i + 1].raw == "f", !typeF { typeF = true; i += 2 }
            else if r == "-not" || r == "!", rest >= 3, s[i + 1].raw == "-path", !s[i + 2].globbed, s[i + 2].value == "*/.*", !noHidden {
                noHidden = true; i += 3
            }
            else { return nil }
        }
        guard let pat, !pat.globbed, pat.value.hasPrefix("*"), matches(String(pat.value.dropFirst()), #"^[A-Za-z0-9._-]+$"#) else { return nil }
        var d = dir.raw
        while d.count > 1, d.hasSuffix("/") { d.removeLast() }
        guard d != "/" else { return nil }
        let hidden = d.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
        guard noHidden, !typeF, !hidden, matches(pat.value, #"^\*\.[A-Za-z0-9]+$"#) else { return (dir, nil) }
        return (dir, (d == "." ? "" : d + "/") + "**" + pat.value.dropFirst())
    }

    /// An awk program that is one `{…}` action, which a leading pattern then guards completely. NR, FNR and getline
    /// would see other lines once grep no longer drops them.
    static func isSingleAction(_ p: String) -> Bool {
        guard p.hasPrefix("{"), p.hasSuffix("}"), !p.contains("'"), !p.contains("\\"),
              !p.contains("NR"), !p.contains("getline") else { return false }
        var depth = 0
        for (n, ch) in p.enumerated() {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 && n != p.count - 1 { return false } }
        }
        return depth == 0
    }

    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func emit<S: Sequence<Word>>(_ ws: S) -> String { ws.map(\.raw).joined(separator: " ") }
    static func join<S: Sequence<[Word]>>(_ st: S) -> String { st.map { emit($0) }.joined(separator: " | ") }
}

extension Word {
    var isFlag: Bool { value.count > 1 && value.hasPrefix("-") }

    /// One file name with nothing the shell expands: no glob, variable, substitution or brace.
    var isPlainFile: Bool {
        !isFlag && !value.isEmpty && value != "-" && !globbed && !raw.contains(where: { "$`(){}\n".contains($0) })
    }
}
