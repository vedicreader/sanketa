import Foundation

public protocol CommandRunning {
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String?
    /// `run`, and a short line on how the run went, for Copy Debug Info
    func report(_ path: String, _ args: [String], timeout: TimeInterval) -> (out: String?, how: String)
}

public extension CommandRunning {
    func run(_ path: String, _ args: [String]) -> String? { run(path, args, timeout: 1.0) }
    func report(_ path: String, _ args: [String], timeout: TimeInterval) -> (out: String?, how: String) {
        let out = run(path, args, timeout: timeout)
        return (out, out == nil ? "failed" : "ok")
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    /// stdout when the command exits 0 within `timeout`; stderr goes to /dev/null
    public func run(_ path: String, _ args: [String], timeout: TimeInterval = 1.0) -> String? {
        exec(path, args, timeout: timeout, keepErr: false).out
    }

    /// `run`, with stderr read too. `how` is `exit 1 in 4 ms: <first line of stderr>`, `no exit after 1.0 s`,
    /// `exit 0, output still open after 1 s` or `did not start: <error>`.
    public func report(_ path: String, _ args: [String], timeout: TimeInterval = 1.0) -> (out: String?, how: String) {
        exec(path, args, timeout: timeout, keepErr: true)
    }

    func exec(_ path: String, _ args: [String], timeout: TimeInterval, keepErr: Bool) -> (out: String?, how: String) {
        let p = Process(), pipe = Pipe(), errPipe = Pipe(), done = DispatchSemaphore(value: 0), start = Date()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = keepErr ? errPipe : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (nil, "did not start: \(error.localizedDescription)") }
        final class Box: @unchecked Sendable { var data = Data(), err = Data() }
        let box = Box(), read = DispatchSemaphore(value: 0), readErr = DispatchSemaphore(value: 0)
        let fh = pipe.fileHandleForReading, eh = errPipe.fileHandleForReading
        Thread.detachNewThread { box.data = fh.readDataToEndOfFile(); read.signal() }
        if keepErr { Thread.detachNewThread { box.err = eh.readDataToEndOfFile(); readErr.signal() } }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return (nil, "no exit after \(timeout) s")
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000), status = p.terminationStatus, deadline = DispatchTime.now() + 1
        // a grandchild still holding the pipe: the reader may still be writing `box.data`
        guard read.wait(timeout: deadline) == .success else { return (nil, "exit \(status), output still open after 1 s") }
        let err = keepErr && readErr.wait(timeout: deadline) == .success
            ? String(decoding: box.err, as: UTF8.self).split(separator: "\n").first.map { ": \($0.prefix(200))" } ?? "" : ""
        return (status == 0 ? String(decoding: box.data, as: UTF8.self) : nil, "exit \(status) in \(ms) ms" + err)
    }
}
