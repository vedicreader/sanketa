import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// The remote scripts run for real, locally: real fish, real bash, real tmux on a private socket,
/// and remote-setup.sh against a temporary HOME. Nothing here contacts another host.
@Suite(.serialized) struct RemoteScriptsSystemTests {
    let r = ProcessRunner()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let scripts = repo.appendingPathComponent("scripts").path
    let fish = "/opt/homebrew/bin/fish"

    /// run with a controlled environment: `env -u TMUX -u XDG_CONFIG_HOME [VAR=val…] cmd…`
    func run(_ env: [String], _ cmd: [String]) -> String? {
        r.run("/usr/bin/env", ["-u", "TMUX", "-u", "XDG_CONFIG_HOME", "-u", "PROMPT_COMMAND"] + env + cmd, timeout: 30)   // real shells: room for a busy Mac
    }

    var host: String {
        // a busy Mac can be slow to start hostname; a nil answer fails the test that needs it, and does not crash the run
        let h = (r.run("/bin/hostname", ["-s"], timeout: 30) ?? "no-hostname").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String(h.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" }).prefix(64))
    }

    func fishTitle(_ env: [String], _ call: String) throws -> RemoteTag {
        let out = try #require(run(env, [fish, "--no-config", "-c", "source \(Self.scripts)/remote/sanketa.fish; \(call)"]))
        return try #require(RemoteTag.parse(out).tag, "\(out)")
    }

    @Test func fishTitleTag() throws {
        #expect(try fishTitle([], "fish_title") == RemoteTag(host: host, layers: ["fish"]))
        #expect(try fishTitle(["TMUX=/tmp/tmux-1/default,1,0"], "fish_title") == RemoteTag(host: host, layers: ["fish", "tmux"]))
        #expect(try fishTitle(["TMUX=x"], "fish_title htop") == RemoteTag(host: host, layers: ["fish", "tmux", "htop"]))
        #expect(try fishTitle([], "fish_title '/usr/bin/nv:top -d 1'") == RemoteTag(host: host, layers: ["fish", "nv_top"]))
        #expect(try fishTitle([], "fish_title fish") == RemoteTag(host: host, layers: ["fish"]))
        #expect(try fishTitle([], "fish_title 'FOO=1 BAR=2 make -j4'") == RemoteTag(host: host, layers: ["fish", "make"]))
        // sourcing twice keeps the original default title instead of recursing into itself
        let out = try #require(run([], [fish, "--no-config", "-c",
            "source \(Self.scripts)/remote/sanketa.fish; source \(Self.scripts)/remote/sanketa.fish; fish_title vim"]))
        #expect(RemoteTag.parse(out).tag == RemoteTag(host: host, layers: ["fish", "vim"]))
        #expect(RemoteTag.parse(out).rest.hasPrefix("vim "))
    }

    /// every `ESC ] 0 ; … BEL` title the output sets, in order
    func titles(_ out: String) -> [String] {
        out.components(separatedBy: "\u{1b}]0;").dropFirst().compactMap { $0.components(separatedBy: "\u{07}").first }
    }

    func bash(_ env: [String], _ script: String, interactive: Bool = false, before: String = "") throws -> String {
        try #require(run(env, ["/bin/bash", "--noprofile", "--norc"] + (interactive ? ["-i"] : [])
            + ["-c", "\(before) source \(Self.scripts)/remote/sanketa.bash; \(script)"]))
    }

    @Test func bashTitleTag() throws {
        let plain = titles(try bash([], "__sanketa_prompt"))
        #expect(plain.map { RemoteTag.parse($0).tag } == [RemoteTag(host: host, layers: ["bash"])])
        let tm = titles(try bash(["TMUX=x"], "__sanketa_prompt; __sanketa_title 'htop -d 1'; __sanketa_title 'a:b'; __sanketa_title 'FOO=1 make'"))
        #expect(tm.map { RemoteTag.parse($0).tag } == [RemoteTag(host: host, layers: ["bash", "tmux"]),
                                                       RemoteTag(host: host, layers: ["bash", "tmux", "htop"]),
                                                       RemoteTag(host: host, layers: ["bash", "tmux", "a_b"]),
                                                       RemoteTag(host: host, layers: ["bash", "tmux", "make"])])
        #expect(RemoteTag.parse(tm[1]).rest == "htop -d 1")
    }

    /// hooks install only in interactive shells (scp sessions read .bashrc too), once, and the DEBUG trap titles the command
    @Test func bashHooks() throws {
        let quiet = try bash([], "__sanketa_debug; /usr/bin/true; echo \"pc=$PROMPT_COMMAND trap=$(trap -p DEBUG)\"")
        #expect(quiet == "pc= trap=\n")
        // `eval "$PROMPT_COMMAND"` stands in for bash drawing a prompt
        let out = try bash([], """
            source \(Self.scripts)/remote/sanketa.bash; echo "pc=$PROMPT_COMMAND"; eval "$PROMPT_COMMAND"; FOO=1 BAR=2 /usr/bin/true x
            """, interactive: true)
        #expect(out.hasPrefix("pc=eval \"$__sanketa_on_prompt\"\n"))
        #expect(titles(out).map { RemoteTag.parse($0).tag } == [RemoteTag(host: host, layers: ["bash"]),
                                                                RemoteTag(host: host, layers: ["bash", "true"])])
    }

    /// a DEBUG trap the user (or a terminal's shell integration) set first keeps firing, with the command's $?
    @Test func bashChainsExistingDebugTrap() throws {
        let out = try #require(run([], ["/bin/bash", "--noprofile", "--norc", "-i", "-c", """
            trap 'echo "user-trap[$?] $BASH_COMMAND"' DEBUG
            source \(Self.scripts)/remote/sanketa.bash
            eval "$PROMPT_COMMAND"
            /usr/bin/false
            /usr/bin/true y
            echo "trap=$(trap -p DEBUG)"
            """]))
        #expect(out.contains("user-trap[0] /usr/bin/false\n"))
        #expect(out.contains("user-trap[1] /usr/bin/true y\n"))
        #expect(out.contains("trap=trap -- '__sanketa_debug' DEBUG\n"))
        #expect(titles(out).compactMap { RemoteTag.parse($0).tag?.layers } == [["bash"], ["bash", "false"]])
    }

    /// with bash-preexec loaded, the snippet joins its hook arrays and leaves the DEBUG trap alone
    @Test func bashJoinsBashPreexec() throws {
        let out = try bash([], """
            echo "pc=$PROMPT_COMMAND trap=$(trap -p DEBUG) pre=${preexec_functions[*]} cmd=${precmd_functions[*]}"; __sanketa_preexec 'FOO=1 make -j4'
            """, interactive: true, before: "bash_preexec_imported=defined; preexec_functions=(x); precmd_functions=(y);")
        #expect(out.hasPrefix("pc= trap= pre=x __sanketa_preexec cmd=y __sanketa_prompt"))
        #expect(titles(out).map { RemoteTag.parse($0).tag } == [RemoteTag(host: host, layers: ["bash", "make"])])
    }

    @Test func remoteSetupLocalHomeIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let bashrc = home.appendingPathComponent(".bashrc"), tmuxConf = home.appendingPathComponent(".tmux.conf")
        try "alias ll='ls -l'\n".write(to: bashrc, atomically: true, encoding: .utf8)
        try "set -g mouse on\n".write(to: tmuxConf, atomically: true, encoding: .utf8)
        func setup() throws -> String {
            try #require(run(["SANKETA_SETUP_LOCAL_HOME=\(home.path)"], ["/bin/sh", "\(Self.scripts)/remote-setup.sh", "gpubox"]))
        }
        let first = try setup()
        for f in ["sanketa.fish", "sanketa.bash", "tmux.conf"] {
            #expect(FileManager.default.contentsEqual(atPath: home.path + "/.config/sanketa/remote/" + f,
                                                      andPath: Self.scripts + "/remote/" + f), "\(f)")
        }
        #expect(FileManager.default.contentsEqual(atPath: home.path + "/.config/fish/conf.d/sanketa.fish",
                                                  andPath: Self.scripts + "/remote/sanketa.fish"))
        #expect(first.contains("copied     ~/.config/fish/conf.d/sanketa.fish"))
        #expect(first.contains("appended   ~/.bashrc") && first.contains("appended   ~/.tmux.conf"))

        let second = try setup()
        #expect(second.contains("unchanged  ~/.config/fish/conf.d/sanketa.fish"))
        #expect(second.contains("unchanged  ~/.bashrc") && second.contains("unchanged  ~/.tmux.conf"))
        let b = try String(contentsOf: bashrc, encoding: .utf8), t = try String(contentsOf: tmuxConf, encoding: .utf8)
        #expect(b.hasPrefix("alias ll='ls -l'\n") && t.hasPrefix("set -g mouse on\n"))
        #expect(b.components(separatedBy: "# sanketa remote layers").count == 2)
        #expect(t.components(separatedBy: "# sanketa remote layers").count == 2)

        // the installed hooks work in that HOME: fish's conf.d, an interactive bash's .bashrc, tmux's config
        let ft = try #require(run(["HOME=\(home.path)"], [fish, "-c", "fish_title"]))
        #expect(RemoteTag.parse(ft).tag == RemoteTag(host: host, layers: ["fish"]))
        let pc = try #require(run(["HOME=\(home.path)"], ["/bin/bash", "--noprofile", "-i", "-c", "echo \"pc=$PROMPT_COMMAND\""]))
        #expect(pc == "pc=eval \"$__sanketa_on_prompt\"\n")
        let sock = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-setup"
        defer { stopTmux(sock, timeout: 3) }
        _ = try #require(run(["HOME=\(home.path)"], [tmuxBin, "-L", sock, "-f", tmuxConf.path, "new", "-d", "-s", "s"]))
        let opt = { (o: String) in self.r.run(tmuxBin, ["-L", sock, "show", "-gv", o], timeout: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(opt("set-titles") == "on" && opt("set-titles-string") == "#{pane_title}" && opt("allow-rename") == "on")
        #expect(opt("mouse") == "on")
    }

    /// `--install-here` run by hand (here: against a temp HOME) refuses and writes nothing
    @Test func installHereRefusesWithoutSetupInvocation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(run(["HOME=\(home.path)"], ["/bin/sh", "\(Self.scripts)/remote-setup.sh", "--install-here"]) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func remoteSetupWithoutHostPrintsUsage() throws {
        #expect(run([], ["/bin/sh", "\(Self.scripts)/remote-setup.sh"]) == nil)
        let make = try #require(run([], ["/bin/sh", "-c", "make -s -C \(Self.repo.path) remote-setup 2>&1; echo rc=$?"]))
        #expect(make.hasPrefix("usage: make remote-setup HOST=") && make.contains("rc=2"))
    }

    /// Real /usr/bin/ssh, no network: `-O check` only looks for a local control socket.
    @Test func realSSHWithoutMasterIsQuickAndQuiet() {
        final class Counting: CommandRunning, @unchecked Sendable {
            var calls = 0
            func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
                calls += 1
                return ProcessRunner().run(path, args, timeout: timeout)
            }
        }
        let c = Counting(), start = Date()
        #expect(RemoteQuery(runner: c).paneCommand(sshArgv: ["ssh", "-p", "2222", "me@nonexistent.invalid", "htop"]) == nil)
        #expect(Date().timeIntervalSince(start) <= 2)
        #expect(c.calls == 1)
    }
}
