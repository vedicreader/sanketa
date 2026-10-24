import Foundation

public protocol CommandRunning {
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String?
}

public extension CommandRunning {
    func run(_ path: String, _ args: [String]) -> String? { run(path, args, timeout: 1.0) }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, _ args: [String], timeout: TimeInterval = 1.0) -> String? {
        let p = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), read = DispatchSemaphore(value: 0)
        let fh = pipe.fileHandleForReading
        Thread.detachNewThread { box.data = fh.readDataToEndOfFile(); read.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        _ = read.wait(timeout: .now() + 1)
        return p.terminationStatus == 0 ? String(decoding: box.data, as: UTF8.self) : nil
    }
}
