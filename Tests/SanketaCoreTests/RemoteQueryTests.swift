import Foundation
import Testing
@testable import SanketaCore

/// Records every command and answers from a table keyed by the ssh subcommand.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    var calls: [(path: String, args: [String], timeout: TimeInterval)] = []
    var check: String?
    var query: String?
    init(check: String?, query: String?) { self.check = check; self.query = query }
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        calls.append((path, args, timeout))
        return args.contains("-O") ? check : query
    }
}

@Suite struct SSHArgsTests {
    @Test func destinationParsing() {
        #expect(SSHArgs.destination(["ssh", "-p", "22", "-i", "k", "me@gpubox"]) == "me@gpubox")
    }

    @Test func destinationIsFirstNonOptionNotLast() {
        #expect(SSHArgs.destination(["ssh", "gpubox", "nvidia-smi", "-l", "1"]) == "gpubox")
        #expect(SSHArgs.destination(["ssh", "-t", "me@gpubox", "tmux", "attach"]) == "me@gpubox")
    }

    @Test func destinationSkipsEveryValuedOption() {
        for o in ["-p", "-l", "-i", "-o", "-J", "-F", "-L", "-R", "-D", "-b", "-c", "-E", "-e", "-I", "-m", "-O",
                  "-Q", "-S", "-W", "-w", "-B"] {
            #expect(SSHArgs.destination(["ssh", o, "value", "gpubox", "cmd"]) == "gpubox", "\(o)")
        }
    }

    @Test func destinationHandlesCombinedAndInlineFlags() {
        #expect(SSHArgs.destination(["ssh", "-tt", "gpubox"]) == "gpubox")
        #expect(SSHArgs.destination(["ssh", "-At", "gpubox", "htop"]) == "gpubox")
        #expect(SSHArgs.destination(["ssh", "-Ap", "2222", "gpubox"]) == "gpubox")   // valued flag last in a cluster
        #expect(SSHArgs.destination(["ssh", "-p2222", "-oBatchMode=yes", "gpubox"]) == "gpubox")
        #expect(SSHArgs.destination(["ssh", "-v", "--", "gpubox", "ls"]) == "gpubox")
        #expect(SSHArgs.destination(["ssh", "-p", "22"]) == nil)
        #expect(SSHArgs.destination(["ssh"]) == nil)
    }

    @Test func hostDropsUserPortAndScheme() {
        #expect(SSHArgs.parse(["ssh", "me@gpubox"])?.host == "gpubox")
        #expect(SSHArgs.parse(["ssh", "ssh://me@gpubox:2222"])?.destination == "ssh://me@gpubox:2222")
        #expect(SSHArgs.parse(["ssh", "ssh://me@gpubox:2222"])?.host == "gpubox")
        #expect(SSHArgs.parse(["ssh", "ssh://gpubox"])?.host == "gpubox")
        #expect(SSHArgs.parse(["ssh", "ssh://me@[fe80::1]:22"])?.host == "fe80::1")
        #expect(SSHArgs.parse(["ssh", "gpubox.lan"])?.host == "gpubox.lan")
    }

    /// options that change which control socket ssh uses travel with the destination
    @Test func connectionOptionsAreKept() {
        let a = SSHArgs.parse(["ssh", "-A", "-p", "2222", "-i", "k", "-L", "8888:localhost:8888", "-oUser=me",
                               "-o", "ForwardX11=yes", "-l", "u", "-F", "cfg", "gpubox", "htop"])
        #expect(a?.options == ["-p", "2222", "-o", "User=me", "-l", "u", "-F", "cfg"])
    }
}

@Suite struct RemoteQueryTests {
    let check = ["-o", "BatchMode=yes", "-O", "check", "me@gpubox"]

    @Test func noControlMasterNoQuery() {
        let f = FakeRunner(check: nil, query: "htop\n")
        #expect(RemoteQuery(runner: f).paneCommand(sshArgv: ["ssh", "me@gpubox"]) == nil)
        #expect(f.calls.count == 1)
        #expect(f.calls[0].path == "/usr/bin/ssh" && f.calls[0].args == check && f.calls[0].timeout == 1)
    }

    @Test func queriesWhenMasterExists() {
        let f = FakeRunner(check: "", query: "htop\n")
        #expect(RemoteQuery(runner: f).paneCommand(sshArgv: ["ssh", "-p", "22", "-i", "k", "me@gpubox", "tmux", "a"]) == "htop")
        #expect(f.calls.count == 2)
        #expect(f.calls[0].args == ["-o", "BatchMode=yes", "-p", "22", "-O", "check", "me@gpubox"])
        #expect(f.calls[1].path == "/usr/bin/ssh" && f.calls[1].timeout == 2)
        #expect(f.calls[1].args == ["-o", "BatchMode=yes", "-p", "22", "me@gpubox", "tmux", "display", "-p",
                                    "'#{pane_current_command}'"])
        #expect(f.calls[1].args.last == "'#{pane_current_command}'")
    }

    @Test func emptyAnswerIsNil() {
        let f = FakeRunner(check: "", query: "\n")
        #expect(RemoteQuery(runner: f).paneCommand(sshArgv: ["ssh", "gpubox"]) == nil)
    }

    @Test func cachesPerDestination() {
        let f = FakeRunner(check: "", query: "nvtop\n")
        let q = RemoteQuery(runner: f)
        #expect(q.paneCommand(sshArgv: ["ssh", "gpubox"]) == "nvtop")
        #expect(q.paneCommand(sshArgv: ["ssh", "gpubox"]) == "nvtop")
        #expect(f.calls.count == 2)   // one check + one query
        #expect(q.paneCommand(sshArgv: ["ssh", "other"]) == "nvtop")
        #expect(f.calls.count == 4)
    }

    @Test func cachedFailureIsNotRetried() {
        let f = FakeRunner(check: nil, query: nil)
        let q = RemoteQuery(runner: f)
        _ = q.paneCommand(sshArgv: ["ssh", "gpubox"])
        _ = q.paneCommand(sshArgv: ["ssh", "gpubox"])
        #expect(f.calls.count == 1)
    }

    @Test func cacheExpires() {
        let f = FakeRunner(check: "", query: "htop\n")
        let q = RemoteQuery(runner: f, cacheSeconds: 0.1)
        _ = q.paneCommand(sshArgv: ["ssh", "gpubox"])
        Thread.sleep(forTimeInterval: 0.2)
        _ = q.paneCommand(sshArgv: ["ssh", "gpubox"])
        #expect(f.calls.count == 4)
    }

    @Test func noDestinationRunsNothing() {
        let f = FakeRunner(check: "", query: "htop\n")
        #expect(RemoteQuery(runner: f).paneCommand(sshArgv: ["ssh", "-V"]) == nil)
        #expect(f.calls.isEmpty)
    }
}
