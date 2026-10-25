import Foundation

public enum MCPError: Error, Equatable {
    /// the server is not running, or it stopped
    case notRunning
    case timeout
    /// a bad reply, or a JSON-RPC error
    case protocolError(String)
    /// the tool ran and failed
    case tool(String)
    case http(Int)
}

/// One way to send JSON-RPC messages to an MCP server. `request` waits for the reply with the same id.
public protocol MCPTransport: AnyObject, Sendable {
    func request(_ message: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ message: [String: Any]) async throws
    var isAlive: Bool { get }
    func close()
}

/// Races `body` against `seconds`; the loser is cancelled.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await body() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw MCPError.timeout }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}

/// An MCP server that Sanketa starts as a child process and talks to over its standard input and output: one JSON
/// message on each line. Its standard error goes nowhere. The child stops when Sanketa calls `close` or quits.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe()
    let lock = NSLock()
    var buffer = Data()
    var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    public init(command: String, arguments: [String] = [], environment: [String: String] = [:]) throws {
        // a write to a child that stopped must give an error, not stop Sanketa
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.read(h.availableData) }
        process.terminationHandler = { [weak self] _ in self?.failAll() }
        try process.run()
    }

    deinit { close() }

    public var isAlive: Bool { process.isRunning }

    public func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        failAll()
    }

    func read(_ d: Data) {
        guard !d.isEmpty else { output.fileHandleForReading.readabilityHandler = nil; return failAll() }
        var lines: [Data] = []
        lock.withLock {
            buffer.append(d)
            while let i = buffer.firstIndex(of: 10) {
                lines.append(buffer.subdata(in: buffer.startIndex..<i))
                buffer.removeSubrange(buffer.startIndex...i)
            }
        }
        for l in lines { deliver(l) }
    }

    /// A reply goes to the request with its id; the server's own requests and notifications are ignored.
    func deliver(_ line: Data) {
        guard let m = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], m["method"] == nil,
              let id = m["id"] as? Int else { return }
        let k = lock.withLock { pending.removeValue(forKey: id) }
        k?.resume(returning: m)
    }

    func failAll() {
        let ks = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
            defer { pending = [:] }
            return Array(pending.values)
        }
        for k in ks { k.resume(throwing: MCPError.notRunning) }
    }

    func write(_ message: [String: Any]) throws {
        guard process.isRunning else { throw MCPError.notRunning }
        var d = try JSONSerialization.data(withJSONObject: message)
        d.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: d) } catch { throw MCPError.notRunning }
    }

    public func notify(_ message: [String: Any]) async throws { try write(message) }

    public func request(_ message: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let id = message["id"] as? Int else { throw MCPError.protocolError("request without id") }
        nonisolated(unsafe) let message = message
        return try await withTimeout(timeout) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<[String: Any], Error>) in
                    let cancelled = lock.withLock { () -> Bool in
                        if Task.isCancelled { return true }
                        pending[id] = k
                        return false
                    }
                    if cancelled { return k.resume(throwing: CancellationError()) }
                    do { try write(message) } catch {
                        lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
                    }
                }
            } onCancel: {
                lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }
    }
}

/// An MCP server that runs already and listens for Streamable HTTP on this Mac, such as `vishalakshi-mcp --http`.
/// It keeps the session id that the server gives, and reads a reply as JSON or as server-sent events.
public final class HTTPTransport: MCPTransport, @unchecked Sendable {
    let url: URL
    let session: URLSession
    let lock = NSLock()
    var sessionID: String?

    public init(url: URL) {
        self.url = url
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c)
    }

    public var isAlive: Bool { true }
    public func close() { session.invalidateAndCancel() }

    func post(_ message: [String: Any], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let s = lock.withLock({ sessionID }) { r.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        r.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await session.data(for: r) } catch let e as URLError where e.code == .timedOut { throw MCPError.timeout }
        catch { throw MCPError.notRunning }
        guard let h = resp as? HTTPURLResponse else { throw MCPError.protocolError("no HTTP reply") }
        guard (200..<300).contains(h.statusCode) else { throw MCPError.http(h.statusCode) }
        if let s = h.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.withLock { sessionID = s } }
        return (d, h)
    }

    public func notify(_ message: [String: Any]) async throws { _ = try await post(message, timeout: 5) }

    public func request(_ message: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        nonisolated(unsafe) let message = message
        let (d, h) = try await withTimeout(timeout) { [self] in try await post(message, timeout: timeout + 1) }
        let id = message["id"] as? Int
        let replies = (h.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/event-stream")
            ? Self.events(String(decoding: d, as: UTF8.self)) : [d]
        for r in replies {
            if let m = (try? JSONSerialization.jsonObject(with: r)) as? [String: Any], m["method"] == nil, m["id"] as? Int == id { return m }
        }
        throw MCPError.protocolError("no reply with id \(id ?? -1)")
    }

    /// The data of each server-sent event in `text`.
    static func events(_ text: String) -> [Data] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { e in
            let data = e.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).drop { $0 == " " } }
            return data.isEmpty ? nil : Data(data.joined(separator: "\n").utf8)
        }
    }
}

/// An MCP client for tool calls. It connects on first use: `initialize`, then `notifications/initialized`. Calls
/// that come while it connects wait for the same connection. A failed start is tried again after `retryAfter`
/// seconds. A child that Sanketa started stops after `idle` seconds with no call.
public final class MCPClient: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    let make: @Sendable () throws -> MCPTransport
    let startTimeout: TimeInterval
    let idle: TimeInterval
    let retryAfter: TimeInterval
    let lock = NSLock()
    var transport: MCPTransport?
    var starting: Task<MCPTransport, Error>?
    var failedAt: Date?
    var idleTask: Task<Void, Never>?
    var nextID = 1

    public init(startTimeout: TimeInterval = 20, idle: TimeInterval = 600, retryAfter: TimeInterval = 60,
                make: @escaping @Sendable () throws -> MCPTransport) {
        self.make = make; self.startTimeout = startTimeout; self.idle = idle; self.retryAfter = retryAfter
    }

    deinit { transport?.close() }

    /// True when the server answered `initialize` and still runs.
    public var isReady: Bool { lock.withLock { transport?.isAlive ?? false } }

    func id() -> Int { lock.withLock { defer { nextID += 1 }; return nextID } }

    /// Starts the connection in the background, if it is not ready and a start is allowed.
    public func warm() { Task { _ = try? await connect() } }

    /// The connection; with `force`, a start that failed a short time ago is tried again (a user action).
    func connect(force: Bool = false) async throws -> MCPTransport {
        let task = try lock.withLock { () throws -> Task<MCPTransport, Error> in
            if let t = transport, t.isAlive { return Task { t } }
            transport = nil
            if let s = starting { return s }
            if !force, let f = failedAt, Date().timeIntervalSince(f) < retryAfter { throw MCPError.notRunning }
            let s = Task { try await self.start() }
            starting = s
            return s
        }
        return try await task.value
    }

    func start() async throws -> MCPTransport {
        do {
            let t = try make()
            do {
                let r = try await t.request(["jsonrpc": "2.0", "id": id(), "method": "initialize", "params": [
                    "protocolVersion": Self.protocolVersion, "capabilities": [String: Any](),
                    "clientInfo": ["name": "sanketa", "version": "1"]]], timeout: startTimeout)
                if let e = r["error"] as? [String: Any] { throw MCPError.protocolError(e["message"] as? String ?? "initialize failed") }
                try await t.notify(["jsonrpc": "2.0", "method": "notifications/initialized"])
            } catch { t.close(); throw error }
            lock.withLock { transport = t; starting = nil; failedAt = nil }
            return t
        } catch {
            lock.withLock { starting = nil; failedAt = Date() }
            throw error
        }
    }

    /// Calls `tool` and gives the JSON of each text part of the reply; a part that is not JSON stays a string.
    public func call(_ tool: String, _ arguments: [String: Any], timeout: TimeInterval, force: Bool = false) async throws -> [Any] {
        let t = try await connect(force: force)
        defer { touch() }
        let r = try await t.request(["jsonrpc": "2.0", "id": id(), "method": "tools/call",
                                     "params": ["name": tool, "arguments": arguments]], timeout: timeout)
        if let e = r["error"] as? [String: Any] { throw MCPError.protocolError(e["message"] as? String ?? "error") }
        guard let res = r["result"] as? [String: Any] else { throw MCPError.protocolError("no result") }
        let texts = (res["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        if res["isError"] as? Bool == true { throw MCPError.tool(texts.joined(separator: " ")) }
        return texts.map { s in (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) ?? s }
    }

    /// The idle clock starts again.
    func touch() {
        guard idle > 0 else { return }
        let wait = idle
        lock.withLock {
            idleTask?.cancel()
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { self?.close() }
            }
        }
    }

    /// Stops a child that Sanketa started; the next call starts it again.
    public func close() {
        let t = lock.withLock { () -> MCPTransport? in
            defer { transport = nil; idleTask?.cancel(); idleTask = nil }
            return transport
        }
        t?.close()
    }
}
