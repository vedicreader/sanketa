import Foundation
import Testing
@testable import SanketaCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let bundledPacksDir = repoRoot.appendingPathComponent("Resources/Packs")

func bundledFiles() -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: bundledPacksDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Runs `bin args...` with `input` on stdin; returns (status, stderr).
func run(_ bin: String, _ args: [String], input: String) throws -> (Int32, String) {
    let p = Process(), inp = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    p.standardInput = inp; p.standardError = err; p.standardOutput = FileHandle.nullDevice
    try p.run()
    inp.fileHandleForWriting.write(Data(input.utf8)); try inp.fileHandleForWriting.close()
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, e)
}

@Suite struct BundledPacksTests {
    static let core = ["tmux", "fish", "bash", "htop", "vim", "git", "grep", "awk", "find", "sed", "pipes", "nvtop", "nvidia-smi", "yazi", "lazygit"]
    static let drafts = ["ramabana", "claude", "conterm", "leela"]
    /// as the app loads them: the leela pack gets Leela's default keymap (no keys.json)
    let lib = { var l = PackLibrary.load(bundled: bundledPacksDir, user: nil); LeelaKeymap.apply(to: &l, keysJSON: nil); return l }()

    @Test func allBundledPacksParse() throws {
        #expect(lib.errors.isEmpty, "\(lib.errors)")
        #expect(Set(lib.packs.keys) == Set(Self.core + Self.drafts))
    }

    @Test func bundledIDsUniqueAndMatchFilename() throws {
        var seen = Set<String>()
        for f in bundledFiles() {
            let p = try PackLibrary.decode(Data(contentsOf: f))
            #expect(p.id == f.deletingPathExtension().lastPathComponent)
            #expect(seen.insert(p.id).inserted, "duplicate id \(p.id)")
        }
        #expect(seen.count == Self.core.count + Self.drafts.count)
    }

    @Test func everyPackHasContent() throws {
        for id in Self.core {
            let p = try #require(lib.packs[id])
            #expect((10...40).contains(p.keys.count) || (5...20).contains(p.tips.count), "\(id)")
            #expect(p.keys.count <= 40 && p.tips.count <= 20, "\(id): \(p.keys.count) keys, \(p.tips.count) tips")
        }
        for p in lib.packs.values {
            #expect(!p.keys.isEmpty || !p.tips.isEmpty, "\(p.id)")
            #expect(!p.processes.isEmpty || !p.match.isEmpty || !p.apps.isEmpty, "\(p.id) never activates")
            for k in p.keys { #expect(!k.keys.isEmpty && !k.action.isEmpty && k.group != nil, "\(p.id): \(k)") }
            for t in p.tips { #expect(!t.snippet.isEmpty && !t.explain.isEmpty && !t.tags.isEmpty, "\(p.id): \(t.title)") }
            let titles = p.tips.map(\.title)
            #expect(Set(titles).count == titles.count, "\(p.id) has duplicate tip titles")
        }
    }

    @Test func tmuxPackHasCommands() throws {
        let t = try #require(lib.packs["tmux"])
        #expect(t.prefix == "C-b")
        for k in t.keys { #expect(k.command != nil && k.keys.hasPrefix("prefix "), "\(k.keys)") }
    }

    @Test func processesCoverRealBinaryNames() throws {
        #expect(lib.pack(process: "nvim", argv: ["nvim"])?.id == "vim")
        #expect(lib.pack(process: "vim", argv: ["vim", "x"])?.id == "vim")
        #expect(lib.pack(process: "vi", argv: ["vi"])?.id == "vim")
        #expect(lib.pack(process: "htop", argv: ["htop"])?.id == "htop")
        #expect(lib.pack(process: "nvtop", argv: ["nvtop"])?.id == "nvtop")
        let smi = try #require(lib.pack(process: "nvidia-smi", argv: ["nvidia-smi", "-l", "1"]))
        #expect(smi.id == "nvidia-smi" && smi.keys.isEmpty && smi.tips.count >= 5)
        #expect(lib.pack(process: "claude", argv: ["claude"])?.id == "claude")
        #expect(lib.pack(process: "yazi", argv: ["yazi", "--cwd-file=/tmp/x"])?.id == "yazi")
        #expect(lib.pack(process: "lazygit", argv: ["lazygit"])?.id == "lazygit")
        #expect(lib.pack(bundleID: "app.conterm.Conterm")?.id == "conterm")
        #expect(lib.pack(bundleID: "org.vedicreader.leela")?.id == "leela")
    }

    /// argv `match` beats process names, so match strings must not claim unrelated programs.
    @Test func argvMatchIsNarrow() throws {
        let rama = ["/Users/x/Library/Application Support/uv/tools/ramabana/bin/python3", "/Users/x/.local/bin/ramabana", "--resume"]
        #expect(lib.pack(process: "python3.12", argv: rama)?.id == "ramabana")
        #expect(lib.pack(process: "nvim", argv: ["nvim", "/Users/x/code/ramabana/ramabana/cli.py"])?.id == "vim")
        #expect(lib.pack(process: "git", argv: ["git", "-C", "ramabana", "log"])?.id == "git")
        #expect(lib.pack(process: "node", argv: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"])?.id == "claude")
        #expect(lib.pack(process: "fish", argv: ["-fish"])?.id == "fish")
        #expect(lib.pack(process: "bash", argv: ["/bin/bash", "--login"])?.id == "bash")
    }

    @Test func everyBundledKeyRendersAsMacSymbols() throws {
        let leftover = try Regex(#"(^|\s)[CMS]-\S|(?i:ctrl|alt|cmd|shift|opt)\+"#)
        for p in lib.packs.values {
            for k in p.keys {
                let shown = KeyNotation.display(k.keys, prefix: p.prefix)
                #expect(shown.firstMatch(of: leftover) == nil, "\(p.id): \(k.keys) -> \(shown)")
                for run in shown.matches(of: try Regex("[⌃⌥⇧⌘]{2,}")).map({ String(shown[$0.range]) }) {
                    #expect(run == KeyNotation.order.filter(run.contains).joined(), "\(p.id): \(k.keys) modifiers not in ⌃⌥⇧⌘ order")
                }
            }
        }
    }

    func tips(_ id: String) throws -> [Tip] { try #require(lib.packs[id]).tips }

    /// File names and paths that mention claude-code or the versions folder are not Claude Code itself.
    @Test func claudeMatchIgnoresFilesNamedLikeIt() throws {
        let r = LayerResolver(library: lib, tmux: FakeTmux(), remote: nil)
        #expect(r.layer("nvim", argv: ["nvim", "notes/claude-code.md"]).packID == "vim")
        #expect(r.layer("git", argv: ["git", "clone", "https://github.com/anthropics/claude-code"]).packID == "git")
        #expect(r.layer("ls", argv: ["ls", "/Users/x/.local/share/claude/versions/"]).packID != "claude")
        #expect(r.layer("node", argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]).packID == "claude")
        #expect(r.layer("2.1.304", argv: ["claude", "-c"]).packID == "claude")
    }

    /// The real-users tip runs on this Mac and prints at least the current user.
    @Test func awkRealUsersTipPrintsUsers() throws {
        let t = try #require(try tips("awk").first { $0.title == "Filter rows by a number" })
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", t.snippet]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let users = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(users.contains(NSUserName()), "\(users)")
    }

    @Test func fishTipsCoverTheBasicsAndParse() throws {
        let all = try tips("fish").map(\.snippet).joined(separator: "\n")
        for needle in ["for ", "if test", "string split", "string replace", "string match", "math ", "set -l", "set -g", "set -gx",
                       "**", "(", " and ", " or ", "psub"] {
            #expect(all.contains(needle), "fish tips lack \(needle)")
        }
        for id in ["fish", "grep", "awk", "find", "sed", "pipes", "git", "nvidia-smi"] {
            for t in try tips(id) {
                let (st, err) = try run("/opt/homebrew/bin/fish", ["--no-config", "--no-execute"], input: t.snippet)
                #expect(st == 0, "\(id) / \(t.title) is not valid fish: \(err)")
            }
        }
    }

    @Test func bashTipsCoverTheBasicsAndParse() throws {
        let all = try tips("bash").map(\.snippet).joined(separator: "\n")
        for needle in ["for ", "while IFS= read", "[[ ", "${", "$(", "set -euo pipefail"] {
            #expect(all.contains(needle), "bash tips lack \(needle)")
        }
        for id in ["bash", "grep", "awk", "find", "sed", "pipes", "git", "nvidia-smi"] {
            for t in try tips(id) {
                let (st, err) = try run("/bin/bash", ["-n"], input: t.snippet)
                #expect(st == 0, "\(id) / \(t.title) is not valid bash: \(err)")
            }
        }
    }

    @Test func dataTipsCoverEverydayTools() throws {
        func has(_ id: String, _ needles: [String]) throws {
            let all = try tips(id).map(\.snippet).joined(separator: "\n")
            for n in needles { #expect(all.contains(n), "\(id) tips lack \(n)") }
        }
        try has("grep", ["grep -rn", "grep -c", "grep -v", "grep -o"])
        try has("awk", ["'{print $2}'", "-F", "s += "])
        try has("find", ["-name", "-mtime", "-exec", "fd "])
        try has("pipes", ["sort | uniq -c | sort -rn", "xargs", "tee"])
    }

    /// Every fenced toml block in docs/packs.md is a complete pack the real decoder accepts.
    @Test func docsExampleDecodes() throws {
        let md = try String(contentsOf: repoRoot.appendingPathComponent("docs/packs.md"), encoding: .utf8)
        let blocks = md.components(separatedBy: "```toml\n").dropFirst().map { $0.components(separatedBy: "\n```")[0] }
        try #require(!blocks.isEmpty)
        let packs = try blocks.map { try PackLibrary.decode(Data($0.utf8)) }
        let example = try #require(packs.first { $0.id == "ramabana" })
        #expect(example.keys.count >= 5 && example.tips.count >= 2 && !example.match.isEmpty)
        let d = try tempDir(["ramabana.toml": blocks[packs.firstIndex(of: example)!]])
        let loaded = PackLibrary.load(bundled: bundledPacksDir, user: d)
        #expect(loaded.errors.isEmpty)
    }
}
