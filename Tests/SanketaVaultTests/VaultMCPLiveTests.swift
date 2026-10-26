import Foundation
import Testing
import SanketaCore
@testable import SanketaVault

/// A real `vishalakshi-mcp`: `SANKETA_MCP_COMMAND`, else the vishalakshi checkout of the author's Mac. With none, these
/// tests are skipped. Writes go to a temporary vault only; the user's vault is only searched.
let liveMCP: String? = {
    let env = ProcessInfo.processInfo.environment["SANKETA_MCP_COMMAND"] ?? ""
    return [env, "~/code/personal/orgs/vishalakshi/.venv/bin/vishalakshi-mcp"].filter { !$0.isEmpty }
        .map { ($0 as NSString).expandingTildeInPath }.first(where: FileManager.default.isExecutableFile)
}()

@Suite(.serialized, .enabled(if: liveMCP != nil)) struct VaultMCPLiveTests {
    @Test func savesANoteInATempVaultAndFindsItByMeaning() async throws {
        let dir = tempFile("vault")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("vault.db").path
        var c = VaultConfig()
        c.path = path
        c.mcpCommand = liveMCP!
        c.mcpTimeoutSeconds = 10
        // no vault file yet: the first save makes it
        let m = try #require(VaultHybrid.make(c))
        let h = try #require(m.writer as? VaultHybrid)
        defer { h.client.close() }
        let t0 = Date()
        let title = try await #require(m.writer).save(text: "Detach from a tmux session with prefix then d.", title: "Leave tmux running")
        print("live: first save (with start) \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        #expect(title == "Leave tmux running")
        let t1 = Date()
        // no word of the query is in the note: only the vector leg can find it
        let r = await h.search("unplug terminal multiplexer")
        print("live: hybrid search \(Int(Date().timeIntervalSince(t1) * 1000)) ms: \(r.map { "\($0.packName)/\($0.title)/\($0.tags)" })")
        #expect(r.first?.title == "Leave tmux running" && r.first?.packName == "vault" && r.first?.tags == ["note"])
    }

    @Test func realVaultReadOnlySmoke() async throws {
        let c = VaultConfig()
        guard FileManager.default.fileExists(atPath: c.resolvedPath()) else { return }
        let client = MCPClient(startTimeout: 30, idle: 0) {
            try StdioTransport(command: liveMCP!, environment: ["VISHALAKSHI_VAULT": c.resolvedPath()])
        }
        let h = VaultHybrid(keyword: VaultSearch(path: c.resolvedPath()), client: client, timeout: 10)
        defer { client.close() }
        let t0 = Date()
        let k = await h.keyword.search("tmux pane")
        print("live: keyword search \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(k.count) results")
        let t1 = Date()
        #expect(await ready(client, 30))
        print("live: server start \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        for q in ["tmux pane", "how do I resume a session", "tmux pane"] {
            let t = Date()
            let r = await h.search(q)
            print("live: hybrid \"\(q)\" \(Int(Date().timeIntervalSince(t) * 1000)) ms: \(r.map { "\($0.packName)/\($0.title.prefix(40))" })")
            #expect(!r.isEmpty)
        }
    }
}
