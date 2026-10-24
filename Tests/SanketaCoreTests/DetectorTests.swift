import Testing
import Foundation
@testable import SanketaCore

struct DetectorTests {
    func run(_ script: String, _ shell: Shell, in dir: URL) -> String? {
        shell == .fish ? runFish(script, in: dir) : runBash(script, in: dir)
    }

    func normalise(_ s: String, _ check: Check) -> String {
        switch check {
        case .exact, .none: return s
        case .trimmed: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .sortedLines, .sortedNoDotSlash:
            let t = check == .sortedNoDotSlash ? s.replacingOccurrences(of: "./", with: "") : s
            return t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: "\n")
        }
    }

    @Test(arguments: positive) func rewritesExample(_ e: Example) {
        let rs = Coach.rewrites(e.input, shell: e.shell)
        #expect(rs.count == 1)
        #expect(rs.first?.detectorID == e.detector)
        #expect(rs.first?.rewrite.before == e.before)
        #expect(rs.first?.rewrite.after == e.after)
    }

    @Test(arguments: negative) func noRewriteForUnsafeInput(_ e: Example) {
        let rs = Coach.rewrites(e.input, shell: e.shell)
        #expect(rs.isEmpty, "\(rs.map(\.rewrite.after))")
    }

    @Test(arguments: positive.filter { $0.check != .none }) func rewriteIsEquivalentInRealShell(_ e: Example) throws {
        let dir = try makeFixtureDir()
        let prefix = e.setup.isEmpty ? "" : e.setup + "; "
        let original = prefix + e.input
        let r = try #require(original.range(of: e.before))
        let rewritten = original.replacingCharacters(in: r, with: e.after)
        let a = try #require(run(original, e.shell, in: dir)), b = try #require(run(rewritten, e.shell, in: dir))
        #expect(!a.isEmpty)
        #expect(normalise(a, e.check) == normalise(b, e.check), "\(rewritten)")
    }

    @Test(arguments: unsafe) func naiveRewriteChangesOutput(_ u: Unsafe) throws {
        // the status line keeps a failing command's (empty) output comparable
        let prefix = u.setup.isEmpty ? "" : u.setup + "; ", status = u.shell == .fish ? "; echo status $status" : "; echo status $?"
        let a = run(prefix + u.input + status, u.shell, in: try makeFixtureDir()).map { normalise($0, u.check) }
        let n = run(prefix + u.naive + status, u.shell, in: try makeFixtureDir()).map { normalise($0, u.check) }
        #expect(a != nil && n != nil)
        #expect(a != n, "\(String(describing: a)) == \(String(describing: n))")
        let afters = Coach.rewrites(u.input, shell: u.shell).map(\.rewrite.after)
        #expect(u.declined ? afters.isEmpty : !afters.isEmpty && !afters.contains(u.naive), "\(afters)")
    }

    @Test func pgrepSuggestionFindsSpawnedProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["37"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        let out = try #require(ProcessRunner().run("/usr/bin/pgrep", ["-fl", "sleep 37"]))
        let pids = out.split(separator: "\n").compactMap { Int32($0.split(separator: " ").first ?? "") }
        #expect(pids.contains(p.processIdentifier))
    }

    @Test func quotedPatternGrepCount() throws {
        let rs = Coach.rewrites("grep 'a|b' a.log | wc -l", shell: .fish)
        #expect(rs.map(\.rewrite.after) == ["grep -c 'a|b' a.log"])
    }

    @Test func substitutionAndOuterBothChecked() {
        let rs = Coach.rewrites("cat a.log | grep (expr 400 + 4)", shell: .fish)
        #expect(rs.map(\.detectorID) == ["useless-cat", "math"])
        #expect(rs.map(\.rewrite.after) == ["grep (expr 400 + 4) a.log", "math 400 + 4"])
    }

    @Test func leadingKeywordIsNotInBefore() {
        let rs = Coach.rewrites("time cat a.log | grep POST", shell: .fish)
        #expect(rs.map(\.rewrite.before) == ["cat a.log | grep POST"])
    }

    @Test func redirectsGiveNoRewrite() {
        #expect(Coach.rewrites("cat a.log | grep x > out.txt", shell: .fish).isEmpty)
        #expect(Coach.rewrites("grep x a.log 2>/dev/null | wc -l", shell: .bash).isEmpty)
    }

    @Test func unsafeVariantsGiveNoRewrite() {
        let cases: [(Shell, String)] = [
            (.fish, "grep x a.log | awk '{print NR}'"), (.fish, "grep x a.log | awk '{print} {print}'"),
            (.fish, "cat a.log | grep x b.log"), (.fish, "cat a.log | head -n 2 b.log"), (.fish, "cat a.log | sed -i s/a/b/"),
            (.bash, "grep -A3 x a.log | wc -l"), (.fish, "grep x *.log | wc -l"), (.fish, "cat a.log | tail -f"),
            (.fish, "ls | grep '.txt$'"), (.fish, #"expr $n \* 2"#), (.bash, "echo '2 ^ 3' | bc"),
            (.fish, "cat a.log | grep -l x"), (.fish, "grep x a{1,2}.log | wc -l"),
        ]
        for (s, line) in cases { #expect(Coach.rewrites(line, shell: s).isEmpty, "\(line)") }
    }

    @Test func titlesAreShort() {
        #expect(Detectors.all.map(\.id) == ["pgrep", "grep-count", "grep-awk", "sort-unique", "find-xargs", "find-glob", "ls-grep",
                                            "glob-loop", "math", "string-split", "string-replace", "string-case", "useless-cat"])
        #expect(Detectors.all.allSatisfy { $0.title.split(separator: " ").count <= 6 })
    }
}
