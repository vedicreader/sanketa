import Foundation
import Testing
import SanketaCore
@testable import SanketaVault

/// The fake server is Fixtures/fake_mcp.py, run by /usr/bin/python3. It starts no window.
let fakeMCP = Bundle.module.url(forResource: "fake_mcp", withExtension: "py", subdirectory: "Fixtures")!.path
let python = "/usr/bin/python3"

func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(name)-\(UUID().uuidString)")
}

func fakeClient(_ flags: [String] = [], log: URL? = nil, startTimeout: TimeInterval = 10) -> MCPClient {
    MCPClient(startTimeout: startTimeout, idle: 0, retryAfter: 60) {
        try StdioTransport(command: python, arguments: [fakeMCP] + flags,
                           environment: log.map { ["FAKE_MCP_LOG": $0.path] } ?? [:])
    }
}

func logged(_ log: URL) -> [[String: Any]] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

/// Waits for the client to be ready, up to `seconds`.
func ready(_ c: MCPClient, _ seconds: Double = 10) async -> Bool {
    c.warm()
    for _ in 0..<Int(seconds * 50) where !c.isReady { try? await Task.sleep(for: .milliseconds(20)) }
    return c.isReady
}

@Suite(.serialized) struct MCPClientTests {
    @Test func stdioCallsAToolAndSkipsTheServersNotifications() async throws {
        let c = fakeClient()
        defer { c.close() }
        let r = try await c.call("federate", ["q": "sandhi"], timeout: 10)
        let hits = (r.first as? [String: Any])?["hits"] as? [[String: Any]]
        #expect(hits?.count == 5 && hits?.first?["title"] as? String == "Vowel sandhi")
        #expect(c.isReady)
    }

    @Test func aToolErrorThrows() async {
        let c = fakeClient(["--fail"])
        defer { c.close() }
        await #expect(throws: MCPError.tool("Error executing tool federate: boom")) { try await c.call("federate", ["q": "x"], timeout: 10) }
    }

    @Test func aSlowCallTimesOutAndTheNextCallStillWorks() async throws {
        let c = fakeClient(["--slow"])
        defer { c.close() }
        #expect(await ready(c))
        let t = Date()
        await #expect(throws: MCPError.timeout) { try await c.call("federate", ["q": "x"], timeout: 0.3) }
        #expect(Date().timeIntervalSince(t) < 2)
        // the late reply of the first call is dropped; the second call gets its own
        let r = try await c.call("federate", ["q": "y"], timeout: 10)
        #expect((r.first as? [String: Any])?["query"] as? String == "y")
    }

    @Test func aMissingProgramFailsAndWaitsBeforeItTriesAgain() async {
        let c = MCPClient(idle: 0, retryAfter: 60) { try StdioTransport(command: "/nonexistent/vishalakshi-mcp") }
        await #expect(throws: (any Error).self) { try await c.call("federate", [:], timeout: 1) }
        await #expect(throws: MCPError.notRunning) { try await c.call("federate", [:], timeout: 1) }
        #expect(!c.isReady)
    }

    @Test func aServerThatStopsIsStartedAgain() async throws {
        let c = fakeClient()
        defer { c.close() }
        _ = try await c.call("federate", ["q": "a"], timeout: 10)
        c.close()
        #expect(!c.isReady)
        _ = try await c.call("federate", ["q": "b"], timeout: 10)
        #expect(c.isReady)
    }

    @Test func idleChildStops() async throws {
        let c = MCPClient(idle: 0.3) { try StdioTransport(command: python, arguments: [fakeMCP]) }
        _ = try await c.call("federate", ["q": "a"], timeout: 10)
        #expect(c.isReady)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!c.isReady)
    }

    @Test func httpKeepsTheSessionAndReadsServerSentEvents() async throws {
        let port = Int.random(in: 20000..<40000)
        let server = try StdioTransport(command: python, arguments: [fakeMCP, "--http", String(port)])
        defer { server.close() }
        let c = MCPClient(startTimeout: 1, idle: 0, retryAfter: 0) { HTTPTransport(url: URL(string: "http://127.0.0.1:\(port)/mcp")!) }
        var r: [Any] = []
        for _ in 0..<50 {
            if let x = try? await c.call("federate", ["q": "sandhi"], timeout: 5) { r = x; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(((r.first as? [String: Any])?["hits"] as? [Any])?.count == 5)
    }

    @Test func serverSentEvents() {
        let e = HTTPTransport.events("event: message\r\ndata: {\"a\":1}\r\n\r\n: ping\n\ndata: x\ndata: y\n\n")
        #expect(e.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "x\ny"])
    }
}

@Suite(.serialized) struct VaultHybridTests {
    @Test func hybridResultsKeepTheirRankAndOpenTheirSource() async throws {
        let log = tempFile("log")
        defer { try? FileManager.default.removeItem(at: log) }
        let h = VaultHybrid(keyword: VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5), client: fakeClient(log: log), timeout: 5)
        defer { h.client.close() }
        #expect(await ready(h.client))
        let r = await h.search("sandhi")
        // RRF order, not grouped by shelf; the second chunk of "Notes on sandhi" and the code hit are left out
        #expect(r.map(\.title) == ["Vowel sandhi", "Notes on sandhi", "Zucchini watering"])
        #expect(r.map(\.packName) == ["learning", "vault", "learning"])
        #expect(r[0].open == URL(string: "http://127.0.0.1:5077/c/vowel-sandhi") && r[0].tags == ["concept"])
        #expect(r[1].open == URL(string: "https://example.com/sandhi") && r[1].explain == "https://example.com/sandhi")
        #expect(r[1].detail.contains("Sandhi"))
        // every shelf that has a document, except the main shelf (the prose leg); no tmp shelf, no code legs
        let call = logged(log).first
        #expect(call?["tool"] as? String == "federate")
        let args = call?["arguments"] as? [String: Any]
        #expect(args?["shelves"] as? [String] == ["learning"])
        #expect(args?["repo"] as? Bool == false && args?["grep"] as? Bool == false && args?["q"] as? String == "sandhi")
    }

    @Test func aServerThatIsNotReadyGivesKeywordResultsAndStarts() async {
        let h = VaultHybrid(keyword: VaultSearch(path: fixture, budget: 5), client: fakeClient(), timeout: 5)
        defer { h.client.close() }
        let r = await h.search("zucchini")
        #expect(Set(r.map(\.title)) == ["Zucchini watering", "Garden reminder"], "the keyword search")
        #expect(await ready(h.client), "the first search started the server")
    }

    @Test func slowOrFailingServerFallsBackToKeywords() async {
        for flag in ["--slow", "--fail"] {
            let h = VaultHybrid(keyword: VaultSearch(path: fixture, budget: 5), client: fakeClient([flag]), timeout: 0.4)
            #expect(await ready(h.client))
            let t = Date()
            let r = await h.search("zucchini")
            #expect(Set(r.map(\.title)) == ["Zucchini watering", "Garden reminder"], "\(flag)")
            #expect(Date().timeIntervalSince(t) < 1.5, "\(flag): time-boxed")
            h.client.close()
        }
    }

    @Test func noServerProgramGivesKeywordSearchOnly() {
        var c = VaultConfig()
        c.path = fixture
        c.mcpCommand = "/nonexistent/vishalakshi-mcp"
        let m = VaultHybrid.make(c)
        #expect(m?.search is VaultSearch && m?.writer == nil)
        c.mcp = false
        c.mcpCommand = python
        #expect(VaultHybrid.make(c)?.writer == nil)
        c.enabled = false
        #expect(VaultHybrid.make(c) == nil)
    }

    @Test func mcpURLMustBeOnThisMac() {
        var c = VaultConfig()
        c.mcpURL = "http://example.com:8000/mcp"
        #expect(VaultHybrid.client(for: c) == nil)
        c.mcpURL = "http://127.0.0.1:8000/mcp"
        #expect(VaultHybrid.client(for: c) != nil)
        c.mcpURL = "file:///tmp/x"
        #expect(VaultHybrid.client(for: c) == nil)
    }

    @Test func saveWritesANoteWithANewKey() async throws {
        let log = tempFile("log")
        defer { try? FileManager.default.removeItem(at: log) }
        let h = VaultHybrid(keyword: VaultSearch(path: fixture), client: fakeClient(log: log))
        defer { h.client.close() }
        #expect(try await h.save(text: "  tmux: prefix d detaches\nmore\n", title: "") == "tmux: prefix d detaches")
        #expect(try await h.save(text: "body", title: "My title") == "My title")
        let calls = logged(log)
        #expect(calls.map { $0["tool"] as? String } == ["note", "note"])
        let a = calls.map { $0["arguments"] as? [String: Any] ?? [:] }
        #expect(a[0]["text"] as? String == "tmux: prefix d detaches\nmore" && a[0]["tags"] as? [String] == ["sanketa"])
        let keys = a.compactMap { $0["key"] as? String }
        #expect(keys.count == 2 && Set(keys).count == 2 && keys.allSatisfy { $0.hasPrefix("sanketa-") })
        await #expect(throws: (any Error).self) { try await h.save(text: "  \n", title: "x") }
    }

    @Test func shelfOfAHit() {
        #expect(VaultHybrid.shelf("prose") == "store" && VaultHybrid.shelf("shelf:ramabana") == "ramabana")
        #expect(VaultHybrid.shelf("repo") == nil && VaultHybrid.shelf("shelf:x]; drop") == nil)
    }

    @Test func titles() {
        #expect(VaultHybrid.title("\n  first line \nsecond") == "first line")
        #expect(VaultHybrid.title(String(repeating: "a", count: 100)).count == 80)
    }
}
