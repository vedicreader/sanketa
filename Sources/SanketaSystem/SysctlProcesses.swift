import Darwin
import Foundation
import SanketaCore

public enum SysctlProcesses {
    public static func snapshot() -> ProcessSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return ProcessSnapshot([]) }
        var buf = [UInt8](repeating: 0, count: size + 64 * MemoryLayout<kinfo_proc>.stride)
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return ProcessSnapshot([]) }
        let n = size / MemoryLayout<kinfo_proc>.stride
        let procs: [ProcInfo] = buf.withUnsafeBytes { raw in
            (0..<n).map { info(raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<kinfo_proc>.stride, as: kinfo_proc.self)) }
        }
        return ProcessSnapshot(procs)
    }

    static func info(_ k: kinfo_proc) -> ProcInfo {
        let pid = k.kp_proc.p_pid
        let path = path(pid)
        var comm = k.kp_proc.p_comm
        let commName = withUnsafeBytes(of: &comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let st = k.kp_proc.p_un.__p_starttime
        return ProcInfo(pid: pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid, tty: tty(k.kp_eproc.e_tdev),
                        tpgid: k.kp_eproc.e_tpgid,
                        name: path.map { ($0 as NSString).lastPathComponent } ?? commName,
                        argv: argv(pid), start: Double(st.tv_sec) + Double(st.tv_usec) / 1e6, path: path)
    }

    static func tty(_ dev: dev_t) -> String? {
        guard dev != dev_t.max, let c = devname(dev, S_IFCHR) else { return nil }
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
