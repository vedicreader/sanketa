import Darwin
import Foundation
import SanketaCore

public enum SysctlProcesses {
    struct Key: Hashable { let pid: Int32, start: Double }
    typealias Detail = (path: String?, argv: [String])
    nonisolated(unsafe) static var details = [Key: Detail]()
    /// `devname` scans /dev with lstat per call; a device number always names the same tty
    nonisolated(unsafe) static var ttyNames = [dev_t: String]()
    static let lock = NSLock()

    /// All processes from one `KERN_PROC_ALL` sysctl; path and argv only for descendants of `roots` and of tmux servers
    /// (every process when `roots` is nil), cached per (pid, start).
    public static func snapshot(under roots: [Int32]? = nil) -> ProcessSnapshot {
        lock.withLock {
            let base = kinfos()
            let want = roots.map { detailed(base, roots: $0) }
            var next = [Key: Detail]()
            let procs = base.map { p -> ProcInfo in
                guard want?.contains(p.pid) ?? true else { return p }
                let k = Key(pid: p.pid, start: p.start)
                let d = details[k] ?? { let path = path(p.pid); return (path, argv(p.pid)) }()
                next[k] = d
                var q = p
                q.path = d.path
                q.argv = d.argv
                if let path = d.path { q.name = (path as NSString).lastPathComponent }
                return q
            }
            // keep cached entries of live processes that weren't detailed this time
            for p in base {
                let k = Key(pid: p.pid, start: p.start)
                if next[k] == nil, let d = details[k] { next[k] = d }
            }
            details = next
            return ProcessSnapshot(procs)
        }
    }

    /// pids below `roots` and below every tmux server (tmux without a tty), roots included
    static func detailed(_ procs: [ProcInfo], roots: [Int32]) -> Set<Int32> {
        let kids = Dictionary(grouping: procs.filter { $0.pid != $0.ppid }, by: \.ppid)
        var queue = roots + procs.filter { $0.name == "tmux" && $0.tty == nil }.map(\.pid)
        var seen = Set(queue)
        while let p = queue.popLast() {
            for c in kids[p] ?? [] where seen.insert(c.pid).inserted { queue.append(c.pid) }
        }
        return seen
    }

    /// cheap kinfo fields of every process; name is `p_comm`, no path or argv. Call with `lock` held.
    static func kinfos() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size + 64 * MemoryLayout<kinfo_proc>.stride)
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return buf.withUnsafeBytes { raw in
            (0..<n).map { i in
                let k = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<kinfo_proc>.stride, as: kinfo_proc.self)
                let dev = k.kp_eproc.e_tdev
                let t = ttyNames[dev] ?? tty(dev)
                if let t { ttyNames[dev] = t }
                return info(k, tty: t)
            }
        }
    }

    static func info(_ k: kinfo_proc, tty: String?) -> ProcInfo {
        var comm = k.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let st = k.kp_proc.p_un.__p_starttime
        return ProcInfo(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid, tty: tty,
                        tpgid: k.kp_eproc.e_tpgid, name: name, argv: [],
                        start: Double(st.tv_sec) + Double(st.tv_usec) / 1e6, path: nil)
    }

    static func tty(_ dev: dev_t) -> String? {
        guard dev != -1, let c = devname(dev, S_IFCHR) else { return nil }   // NODEV: no controlling tty
        let s = String(cString: c)
        return s == "??" ? nil : s
    }

    static func path(_ pid: Int32) -> String? {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &b, UInt32(b.count)) > 0 ? String(cString: b) : nil
    }

    static func argv(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }          // skip exec path
        while i < size && buf[i] == 0 { i += 1 }          // skip padding
        var out = [String]()
        while out.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }
}
