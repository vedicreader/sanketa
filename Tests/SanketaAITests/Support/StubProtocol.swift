import Foundation

/// A request the stub saw, with the body read from `httpBodyStream`.
struct StubRequest: Sendable {
    var url: URL?
    var method: String?
    var headers: [String: String]
    var body: Data
    var timeout: TimeInterval
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

/// Serves canned answers per URL path from memory; nothing leaves the process. Each `Stub` gets its own session, found
/// again through a header, so suites that run in parallel do not share answers or captured requests. The registry
/// holds stubs weakly, and a stub removes itself when its test lets it go.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let idHeader = "X-Sanketa-Stub"
    private static let lock = NSLock()
    private struct Weak { weak var stub: Stub? }
    nonisolated(unsafe) private static var stubs: [String: Weak] = [:]

    static func register(_ s: Stub) { lock.withLock { stubs[s.id] = Weak(stub: s) } }
    static func unregister(_ id: String) { lock.withLock { stubs[id] = nil } }
    static func isRegistered(_ id: String) -> Bool { lock.withLock { stubs[id] != nil } }
    static func stub(for r: URLRequest) -> Stub? {
        guard let id = r.value(forHTTPHeaderField: idHeader) else { return nil }
        return lock.withLock { stubs[id]?.stub }
    }

    override class func canInit(with request: URLRequest) -> Bool { stub(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let (status, body) = stub.answer(request)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Canned `(status, body)` answers per path, used in turn (the last one repeats), and every request seen.
final class Stub: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var answers: [String: [(Int, Data)]]
    private var seen: [StubRequest] = []
    let session: URLSession

    init(_ answers: [String: [(Int, String)]]) {
        self.answers = answers.mapValues { $0.map { ($0.0, Data($0.1.utf8)) } }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        c.httpAdditionalHeaders = [StubProtocol.idHeader: id]
        session = URLSession(configuration: c)
        StubProtocol.register(self)
    }

    deinit {
        session.invalidateAndCancel()
        StubProtocol.unregister(id)
    }

    var requests: [StubRequest] { lock.withLock { seen } }

    fileprivate func answer(_ r: URLRequest) -> (Int, Data) {
        var body = r.httpBody ?? Data()
        if let s = r.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        let req = StubRequest(url: r.url, method: r.httpMethod, headers: r.allHTTPHeaderFields ?? [:], body: body,
                              timeout: r.timeoutInterval)
        return lock.withLock {
            seen.append(req)
            let path = r.url?.path ?? ""
            guard var list = answers[path], !list.isEmpty else { return (404, Data(#"{"error":"no stub"}"#.utf8)) }
            let a = list.count > 1 ? list.removeFirst() : list[0]
            answers[path] = list
            return a
        }
    }
}
