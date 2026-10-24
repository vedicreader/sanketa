import Foundation

public struct ProcInfo: Codable, Hashable {
    public var pid: Int32, ppid: Int32, pgid: Int32
    public var tty: String?
    public var tpgid: Int32
    public var name: String
    public var argv: [String]
    public var start: Double
    public var path: String?
    public init(pid: Int32, ppid: Int32, pgid: Int32, tty: String?, tpgid: Int32, name: String,
                argv: [String], start: Double, path: String?) {
        (self.pid, self.ppid, self.pgid, self.tty, self.tpgid) = (pid, ppid, pgid, tty, tpgid)
        (self.name, self.argv, self.start, self.path) = (name, argv, start, path)
    }
}

public struct ProcessSnapshot {
    public let procs: [ProcInfo]
    private let byPid: [Int32: ProcInfo]
    public init(_ procs: [ProcInfo]) {
        self.procs = procs
        byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }
    public func proc(_ pid: Int32) -> ProcInfo? { byPid[pid] }
    public func children(of pid: Int32) -> [ProcInfo] { procs.filter { $0.ppid == pid && $0.pid != pid } }

    /// ttys of all descendants of `pid`, unique, first-seen order
    public func ttys(under pid: Int32) -> [String] {
        var seen = Set<Int32>([pid]), out = [String](), queue = [pid]
        while !queue.isEmpty {
            for c in children(of: queue.removeFirst()) where seen.insert(c.pid).inserted {
                if let t = c.tty, !out.contains(t) { out.append(t) }
                queue.append(c.pid)
            }
        }
        return out
    }

    public func foreground(tty t: String) -> ProcInfo? {
        let fg = procs.filter { $0.tty == t && $0.pgid == $0.tpgid }
        return fg.first { $0.pid == $0.pgid } ?? fg.max { $0.start < $1.start }
    }

    /// walks ppid upward, innermost first, excluding the stopping proc
    public func chain(from p: ProcInfo, until stop: (ProcInfo) -> Bool) -> [ProcInfo] {
        var out = [ProcInfo](), visited = Set<Int32>(), cur: ProcInfo? = p
        while let c = cur, c.pid > 1, visited.insert(c.pid).inserted, !stop(c) {
            out.append(c)
            cur = proc(c.ppid)
        }
        return out
    }
}
