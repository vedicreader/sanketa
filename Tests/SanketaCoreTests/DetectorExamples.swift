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
    Example(.fish, "find . -name '*.py'", "find-glob", #"printf '%s\n' **.py"#, .sortedNoDotSlash),
    Example(.fish, #"find src -type f -name "*.py""#, "find-glob", #"printf '%s\n' src/**.py"#, .sortedLines),
    Example(.fish, "find . -name '*.py' | xargs wc -l", "find-xargs", "wc -l **.py", .sortedNoDotSlash),
    Example(.bash, "find . -name '*.py' | xargs wc -l", "find-xargs", "find . -name '*.py' -exec wc -l {} +", .sortedLines),
    Example(.fish, "ls | grep log", "ls-grep", "ls -d *log*", .sortedLines),
    Example(.bash, #"ls | grep '\.txt$'"#, "ls-grep", "ls -d *.txt", .sortedLines),
    Example(.fish, "for f in (ls *.log); echo $f; end", "glob-loop", before: "for f in (ls *.log)", "for f in *.log", .sortedLines),
    Example(.bash, #"for f in $(ls *.txt); do echo "$f"; done"#, "glob-loop", before: "for f in $(ls *.txt)", "for f in *.txt", .sortedLines),
    Example(.fish, "for f in (ls); echo $f; end", "glob-loop", before: "for f in (ls)", "for f in *", .sortedLines),
    Example(.fish, "expr 3 + 4", "math", "math 3 + 4", .exact),
    Example(.fish, "set n (expr $n + 1); echo $n", "math", before: "expr $n + 1", "math $n + 1", .exact, setup: "set n 5"),
    Example(.fish, "expr 7 / 2", "math", "math -s0 7 / 2", .exact),
    Example(.fish, #"expr 3 \* 4"#, "math", "math '3 * 4'", .exact),
    Example(.fish, "echo '7 / 2' | bc", "math", "math -s0 '7 / 2'", .exact),
    Example(.bash, "expr 3 + 4", "math", "echo $(( 3 + 4 ))", .exact),
    Example(.bash, "n=$(expr $n + 1); echo $n", "math", before: "$(expr $n + 1)", "$(( $n + 1 ))", .exact, setup: "n=5"),
    Example(.fish, "echo $row | cut -d, -f2", "string-split", "string split -f2 , $row", .exact, setup: "set row a,b,c"),
    Example(.fish, "echo $row | cut -d ':' -f1", "string-split", "string split -f1 : $row", .exact, setup: "set row x:y"),
    Example(.fish, "echo $name | sed 's/foo/bar/g'", "string-replace", "string replace -a foo bar $name", .exact, setup: "set name foo-foo"),
    Example(.fish, "echo $name | sed 's/foo//'", "string-replace", "string replace foo '' $name", .exact, setup: "set name foo-foo"),
    Example(.fish, "echo $name | tr a-z A-Z", "string-case", "string upper $name", .exact, setup: "set name Ada"),
    Example(.fish, "echo $name | tr '[:upper:]' '[:lower:]'", "string-case", "string lower $name", .exact, setup: "set name Ada"),
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
].map { Example($0.0, $0.1, "", "", .none) }

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
