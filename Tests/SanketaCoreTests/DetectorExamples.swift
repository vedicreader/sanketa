import Foundation
import Testing
@testable import SanketaCore

enum Check: Sendable { case exact, trimmed, sortedLines, sortedNoDotSlash, none }

struct Example: Sendable, CustomTestStringConvertible {
    var shell: Shell
    var setup: String
    var input: String
    var detector: String
    var before: String
    var after: String
    var check: Check

    init(_ shell: Shell, _ input: String, _ detector: String, before: String? = nil, _ after: String, _ check: Check, setup: String = "") {
        self.shell = shell; self.setup = setup; self.input = input; self.detector = detector
        self.before = before ?? input; self.after = after; self.check = check
    }

    var testDescription: String { "\(shell.rawValue): \(input)" }
}

let positive: [Example] = [
    Example(.fish, "cat a.log | grep 404 | wc -l", "grep-count", "grep -c 404 a.log", .trimmed),
    Example(.bash, "grep GET a.log | wc -l", "grep-count", "grep -c GET a.log", .trimmed),
    Example(.fish, "sort a.log | grep 404 | wc -l", "grep-count", "sort a.log | grep -c 404", .trimmed),
    Example(.bash, "grep 'GET /gone' a.log | wc -l", "grep-count", "grep -c 'GET /gone' a.log", .trimmed),
    Example(.fish, "cat a.log | grep POST", "useless-cat", "grep POST a.log", .exact),
    Example(.bash, "cat a.log | wc -l", "useless-cat", "wc -l < a.log", .exact),
    Example(.bash, "cat a.log | tr a-z A-Z", "useless-cat", "tr a-z A-Z < a.log", .exact),
    Example(.fish, "cat a.log | head -n 2", "useless-cat", "head -n 2 a.log", .exact),
    Example(.fish, "sort names.txt | uniq", "sort-unique", "sort -u names.txt", .exact),
    Example(.bash, "cat names.txt | sort | uniq", "sort-unique", "sort -u names.txt", .exact),
    Example(.fish, "cut -d, -f1 data.csv | sort | uniq", "sort-unique", "cut -d, -f1 data.csv | sort -u", .exact),
    Example(.bash, "sort -r names.txt | uniq", "sort-unique", "sort -r -u names.txt", .exact),
    Example(.fish, "grep 404 a.log | awk '{print $5}'", "grep-awk", "awk '/404/ {print $5}' a.log", .exact),
    Example(.bash, "cat a.log | grep GET | awk '{print $1}'", "grep-awk", "awk '/GET/ {print $1}' a.log", .exact),
    Example(.fish, "grep 404 a.log | awk -F/ '{print $2}'", "grep-awk", "awk -F/ '/404/ {print $2}' a.log", .exact),
    // hidden entries in the folder: the find skips them as ** does
    Example(.fish, "find . -name '*.py' -not -path '*/.*'", "find-glob", #"printf '%s\n' **.py"#, .sortedNoDotSlash,
            setup: "mkdir -p .venv; touch .venv/x.py .h.py"),
    Example(.fish, "find src ! -path '*/.*' -name '*.py'", "find-glob", #"printf '%s\n' src/**.py"#, .sortedLines,
            setup: "mkdir -p src/.cache; touch src/.cache/z.py"),
    Example(.fish, "find . -name '*.py' -not -path '*/.*' | xargs wc -l", "find-xargs", "wc -l **.py", .sortedNoDotSlash,
            setup: "mkdir -p .venv; touch .venv/x.py .h.py"),
    Example(.bash, "find . -name '*.py' -not -path '*/.*' | xargs wc -l", "find-xargs", "find . -name '*.py' -not -path '*/.*' -exec wc -l {} +",
            .sortedLines, setup: "mkdir -p .venv; touch .venv/x.py"),
    Example(.bash, "find . -name '*.py' | xargs wc -l", "find-xargs", "find . -name '*.py' -exec wc -l {} +", .sortedLines),
    Example(.fish, "ls | grep log", "ls-grep", "ls -d *log*", .sortedLines),
    Example(.bash, #"ls | grep '\.txt$'"#, "ls-grep", "ls -d *.txt", .sortedLines),
    Example(.fish, "for f in (ls *.log); echo $f; end", "glob-loop", before: "for f in (ls *.log)", "for f in *.log", .sortedLines),
    Example(.fish, "for f in (ls); echo $f; end", "glob-loop", before: "for f in (ls)", "for f in *", .sortedLines),
    Example(.fish, "expr 3 + 4", "math", "math 3 + 4", .exact),
    Example(.fish, "expr 7 / 2", "math", "math -s0 7 / 2", .exact),
    Example(.fish, #"expr 3 \* 4"#, "math", "math '3 * 4'", .exact),
    Example(.fish, "echo '7 / 2' | bc", "math", "math -s0 '7 / 2'", .exact),
    Example(.fish, #"expr 2 \* 3 + 1"#, "math", "math '2 * 3 + 1'", .exact),
    Example(.fish, "echo '9 % 4' | bc", "math", "math -s0 '9 % 4'", .exact),
    Example(.bash, "expr 3 + 4", "math", "echo $(( 3 + 4 ))", .exact),
    Example(.bash, "n=$(expr 3 + 4); echo $n", "math", before: "$(expr 3 + 4)", "$(( 3 + 4 ))", .exact),
    Example(.fish, "set n (expr 3 + 4); echo $n", "math", before: "expr 3 + 4", "math 3 + 4", .exact),
    Example(.fish, "echo $row | cut -d, -f1", "string-split", #"string split -f1 , -- "$row""#, .exact, setup: "set row a,b,c"),
    Example(.fish, "echo $row | cut -d, -f1", "string-split", #"string split -f1 , -- "$row""#, .exact, setup: "set row a,b c,d"),
    // no delimiter: same output, but string split exits with status 1, so `; true` lets the runner keep the output
    Example(.fish, "echo $row | cut -d, -f1; true", "string-split", before: "echo $row | cut -d, -f1", #"string split -f1 , -- "$row""#, .exact,
            setup: "set row abc"),
    Example(.fish, "echo $row | cut -d ':' -f1", "string-split", #"string split -f1 : -- "$row""#, .exact, setup: "set row x:y"),
    Example(.fish, "echo $name | sed 's/foo/bar/g'", "string-replace", #"string replace -a foo bar "$name""#, .exact, setup: "set name foo x foo"),
    Example(.fish, "echo $name | sed 's/foo//'", "string-replace", #"string replace foo '' "$name""#, .exact, setup: "set name foo x foo"),
    Example(.fish, "echo $name | tr a-z A-Z", "string-case", #"string upper "$name""#, .exact, setup: "set name Ada Bo"),
    Example(.fish, "echo $name | tr '[:upper:]' '[:lower:]'", "string-case", #"string lower "$name""#, .exact, setup: "set name Ada Bo"),
    Example(.fish, "ps aux | grep sleep", "pgrep", "pgrep -fl sleep", .none),
    Example(.bash, "ps aux | grep node | grep -v grep", "pgrep", "pgrep -fl node", .none),
    Example(.fish, "ps -ef | grep -v grep | grep ssh", "pgrep", "pgrep -fl ssh", .none),
]

let negative: [Example] = [
    (Shell.fish, "grep -o x a.log | wc -l"), (.bash, "grep x a.log names.txt | wc -l"), (.fish, "grep x a.log | wc -w"),
    (.bash, "cat a.log names.txt | grep x"), (.fish, "cat -n a.log | grep x"), (.fish, "cat a.log | while read l; echo $l; end"),
    (.bash, "sort -n nums.txt | uniq"), (.fish, "sort names.txt | uniq -c"), (.fish, "find . -iname '*.py'"),
    (.fish, "find . -name '*.py' -mtime -1"), (.bash, "find . -name '*.py'"), (.fish, "find . -name '*.py' | xargs -n1 wc -l"),
    (.fish, "ls -la | grep x"), (.bash, "ls | grep -v x"), (.fish, "ls | grep 'a.*b'"), (.fish, "for f in (ls -t); echo $f; end"),
    (.fish, "for f in (ls src); echo $f; end"), (.fish, "echo $name | sed 's/a.b/c/g'"), (.fish, "echo $row | cut -d, -f1,3"),
    (.fish, #"printf 'a,b\n' | cut -d, -f2"#), (.fish, "ps aux | grep -i node"), (.fish, "echo 'oops | grep x"),
    (.bash, #"expr length "$s""#), (.bash, "echo '1/3' | bc -l"),
].map { Example($0.0, $0.1, "", "", .none) } + unsafe.filter(\.declined).map { Example($0.shell, $0.input, "", "", .none) }

/// Inputs where an earlier, looser rule gave `naive`, which real fish or bash shows to be wrong. A declined input must
/// give no rewrite; the others must give a rewrite other than `naive`.
struct Unsafe: Sendable, CustomTestStringConvertible {
    var shell: Shell
    var setup: String
    var input: String
    var naive: String
    var check: Check
    var declined: Bool
    var testDescription: String { "\(shell.rawValue): \(input)" }
}

let unsafe: [Unsafe] = [
    // math -s0 and bc cut only the final result
    Unsafe(shell: .fish, setup: "", input: #"expr 7 / 2 \* 2"#, naive: "math -s0 '7 / 2 * 2'", check: .exact, declined: true),
    Unsafe(shell: .fish, setup: "", input: "expr 7 / 2 + 7 / 2", naive: "math -s0 7 / 2 + 7 / 2", check: .exact, declined: true),
    Unsafe(shell: .fish, setup: "", input: "echo '7 / 2 + 7 / 2' | bc", naive: "math -s0 '7 / 2 + 7 / 2'", check: .exact, declined: true),
    // math loses whole numbers above 2^53; bash wraps where expr stops with an overflow error
    Unsafe(shell: .fish, setup: "", input: #"expr 999999999 \* 999999999"#, naive: "math '999999999 * 999999999'", check: .exact, declined: true),
    Unsafe(shell: .bash, setup: "", input: #"expr 999999999 \* 999999999 \* 999"#, naive: "echo $(( 999999999 * 999999999 * 999 ))", check: .exact, declined: true),
    // bash reads a leading zero as octal
    Unsafe(shell: .bash, setup: "", input: "expr 010 + 1", naive: "echo $(( 010 + 1 ))", check: .exact, declined: true),
    // a variable can hold a leading zero or nothing: bash fails on 08, and math and $(( )) give 1 where expr fails
    // (the subshell keeps bash running after "value too great for base", so the status line still prints)
    Unsafe(shell: .bash, setup: "n=08", input: "n=$(expr $n + 1); echo $n", naive: "(n=$(( $n + 1 )); echo $n)", check: .exact, declined: true),
    Unsafe(shell: .bash, setup: "n=", input: "n=$(expr $n + 1); echo $n", naive: "n=$(( $n + 1 )); echo $n", check: .exact, declined: true),
    Unsafe(shell: .fish, setup: "set n", input: "set n (expr $n + 1); echo $n", naive: "set n (math $n + 1); echo $n", check: .exact, declined: true),
    // bash keeps a glob with no match as literal text
    Unsafe(shell: .bash, setup: "", input: #"for f in $(ls *.zzz); do echo "$f"; done"#, naive: #"for f in *.zzz; do echo "$f"; done"#, check: .exact, declined: true),
    // cut prints a line without the delimiter; string split -f2 prints nothing
    Unsafe(shell: .fish, setup: "set row abc", input: "echo $row | cut -d, -f2", naive: "string split -f2 , $row", check: .exact, declined: true),
    // fish has no glob for files only: ** also gives folders
    Unsafe(shell: .fish, setup: "mkdir d.py", input: "find . -type f -name '*.py'", naive: #"printf '%s\n' **.py"#, check: .sortedNoDotSlash, declined: true),
    Unsafe(shell: .fish, setup: "mkdir d.py", input: "find . -type f -name '*.py' | xargs wc -l", naive: "wc -l **.py", check: .sortedNoDotSlash, declined: true),
    // ** skips hidden entries; find without -not -path '*/.*' lists them
    Unsafe(shell: .fish, setup: "mkdir -p .venv; touch .venv/x.py", input: "find . -name '*.py'", naive: #"printf '%s\n' **.py"#,
           check: .sortedNoDotSlash, declined: true),
    Unsafe(shell: .fish, setup: "mkdir -p .venv; touch .venv/x.py", input: "find . -name '*.py' | xargs wc -l", naive: "wc -l **.py",
           check: .sortedNoDotSlash, declined: true),
    // -not -name '.*' skips hidden names, but find still looks inside hidden folders
    Unsafe(shell: .fish, setup: "mkdir -p .venv; touch .venv/x.py", input: "find . -name '*.py' -not -name '.*'", naive: #"printf '%s\n' **.py"#,
           check: .sortedNoDotSlash, declined: true),
    Unsafe(shell: .fish, setup: "touch .zshrc", input: "find . -name '*rc'", naive: #"printf '%s\n' **rc"#, check: .sortedNoDotSlash, declined: true),
    Unsafe(shell: .fish, setup: "mkdir -p .h/.i; touch .h/a.py .h/.i/z.py", input: "find .h -name '*.py'", naive: #"printf '%s\n' .h/**.py"#,
           check: .sortedLines, declined: true),
    // a list variable: echo joins it into one line, an unquoted $VAR gives one argument per element
    Unsafe(shell: .fish, setup: "set row a,b c,d", input: "echo $row | cut -d, -f1", naive: "string split -f1 , $row", check: .exact, declined: false),
    Unsafe(shell: .fish, setup: "set name foo x foo", input: "echo $name | sed 's/foo/bar/'", naive: "string replace foo bar $name", check: .exact, declined: false),
    Unsafe(shell: .fish, setup: "set name a b", input: "echo $name | tr a-z A-Z", naive: "string upper $name", check: .exact, declined: false),
]

/// A fresh folder with the files the examples read. No hidden files.
func makeFixtureDir() throws -> URL {
    let d = try tempDir(), fm = FileManager.default
    try fm.createDirectory(at: d.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
    let files = [
        "a.log": "10.0.0.1 - - GET /index 200 512\n10.0.0.2 - - GET /missing 404 0\n10.0.0.3 - - POST /form 404 0\n10.0.0.1 - - GET /gone 404 0\n",
        "names.txt": "bob\nada\nbob\ncy\nada\n", "data.csv": "a,1\nb,2\na,3\n",
        "top.py": "print(1)\n", "src/x.py": "print(2)\n", "src/sub/y.py": "print(3)\n",
        "old.log": "", "app.log": "", "readme.txt": "", "report.txt": "", "catalog.md": "",
    ]
    for (name, text) in files { try text.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return d
}
