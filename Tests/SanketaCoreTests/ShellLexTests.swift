import Testing
import Foundation
@testable import SanketaCore

struct ShellLexTests {
    func values(_ line: String, _ shell: Shell = .fish) -> [[[String]]] {
        ShellLex.commands(line, shell: shell).map { $0.stages.map { $0.map(\.value) } }
    }

    @Test func pipelineStages() {
        #expect(values("cat a.log | grep 404 | wc -l") == [[["cat", "a.log"], ["grep", "404"], ["wc", "-l"]]])
    }

    @Test func quotedPipeStaysInWord() {
        let cs = ShellLex.commands("grep 'a|b' f | wc -l", shell: .fish)
        #expect(cs.map { $0.stages.map { $0.map(\.value) } } == [[["grep", "a|b", "f"], ["wc", "-l"]]])
        #expect(cs[0].stages[0][1].raw == "'a|b'")
    }

    @Test func separators() {
        let cs = ShellLex.commands("cd /tmp && ls | grep x; echo done", shell: .bash)
        #expect(cs.map(\.text) == ["cd /tmp", "ls | grep x", "echo done"])
        #expect(ShellLex.commands("sleep 1 & ls || pwd", shell: .bash).map(\.text) == ["sleep 1", "ls", "pwd"])
    }

    @Test func fishSubstitution() {
        let cs = ShellLex.commands("set n (expr $n + 1)", shell: .fish)
        #expect(cs.count == 2)
        #expect(cs[0].stages[0].map(\.raw) == ["set", "n", "(expr $n + 1)"])
        #expect(cs[1].stages.map { $0.map(\.value) } == [["expr", "$n", "+", "1"]])
        #expect(cs[1].substitution == .paren && cs[1].wrappedText == "(expr $n + 1)" && cs[0].substitution == nil)
    }

    @Test func bashDollarSubstitutionInDoubleQuotes() {
        let cs = ShellLex.commands("echo \"count: $(grep -c x f)\"", shell: .bash)
        #expect(cs.count == 2)
        #expect(cs[1].stages.map { $0.map(\.value) } == [["grep", "-c", "x", "f"]] && cs[1].substitution == .dollar)
        #expect(cs[1].wrappedText == "$(grep -c x f)")
    }

    @Test func backtickSubstitution() {
        let cs = ShellLex.commands("n=`expr $n + 1`", shell: .bash)
        #expect(cs.count == 2)
        #expect(cs[1].stages.map { $0.map(\.value) } == [["expr", "$n", "+", "1"]] && cs[1].substitution == .backtick)
    }

    @Test func fishKeywordsDropped() {
        let cs = ShellLex.commands("test -f x; and cat x | grep y", shell: .fish)
        #expect(cs.count == 2)
        #expect(cs[1].stages.map { $0.map(\.value) } == [["cat", "x"], ["grep", "y"]])
        #expect(values("time ! ls", .bash) == [[["ls"]]])
    }

    @Test func multilineFishLoop() {
        let cs = ShellLex.commands("for f in (ls *.log)\necho $f\nend", shell: .fish)
        #expect(cs.map(\.text) == ["for f in (ls *.log)", "ls *.log", "echo $f", "end"])
    }

    @Test func unbalancedQuoteGivesNothing() {
        #expect(ShellLex.commands("echo 'oops | grep x", shell: .fish) == [])
        #expect(ShellLex.commands("echo (ls", shell: .fish) == [])
        #expect(ShellLex.commands("echo \"oops", shell: .bash) == [])
        #expect(ShellLex.commands("echo `ls", shell: .bash) == [])
        #expect(ShellLex.commands("echo $(ls", shell: .bash) == [])
    }

    @Test func commentIgnored() {
        #expect(values("ls | grep x # find x") == [[["ls"], ["grep", "x"]]])
        #expect(ShellLex.commands("ls # one\npwd", shell: .fish).map(\.text) == ["ls", "pwd"])
    }

    @Test func globFlag() {
        let w = ShellLex.commands("ls *.log '*.txt'", shell: .fish)[0].stages[0]
        #expect(w.map(\.globbed) == [false, true, false])
    }

    @Test func redirectWords() {
        let w = ShellLex.commands("sort < in.txt > out.txt 2>&1", shell: .bash)[0].stages[0]
        #expect(w.filter(\.isRedirect).map(\.raw) == ["<", ">", "2>&1"])
        #expect(w.count == 6)
    }

    @Test func escapedSpace() {
        #expect(values("echo a\\ b | wc -c") == [[["echo", "a b"], ["wc", "-c"]]])
    }

    @Test func quotesAndEscapes() {
        #expect(values("echo 'it\\'s' \"a \\\" b\" \"\\$x\"") == [[["echo", "it's", "a \" b", "$x"]]])
        #expect(values("echo 'a\\b'", .bash) == [[["echo", "a\\b"]]])
    }

    @Test func nestedSubstitution() {
        let cs = ShellLex.commands("echo (string join , (ls))", shell: .fish)
        #expect(cs.map(\.text) == ["echo (string join , (ls))", "string join , (ls)", "ls"])
        #expect(cs.map(\.substitution) == [nil, .paren, .paren])
    }

    @Test func stderrPipeSplitsStages() {
        #expect(values("make |& tee log", .bash) == [[["make"], ["tee", "log"]]])
        #expect(values("make &| tee log", .fish) == [[["make"], ["tee", "log"]]])
    }
}
