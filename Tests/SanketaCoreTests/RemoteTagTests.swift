import Testing
@testable import SanketaCore

@Suite struct RemoteTagTests {
    @Test func remoteTagParses() {
        let r = RemoteTag.parse("⟦sanketa host=gpubox layers=fish,tmux,htop⟧ ~/w")
        #expect(r.tag == RemoteTag(host: "gpubox", layers: ["fish", "tmux", "htop"]))
        #expect(r.rest == "~/w")
    }

    @Test func remoteTagRejectsGarbage() {
        let nine = (1...9).map { "l\($0)" }.joined(separator: ",")
        for t in ["⟦sanketa host=bad host layers=fish⟧ x", "⟦sanketa host=a/b layers=fish⟧ x",
                  "⟦sanketa host=h layers=\(nine)⟧ x", "⟦sanketa host=h layers=fish x",
                  "⟦sanketa host=h layers=⟧ x", "plain title"] {
            let r = RemoteTag.parse(t)
            #expect(r.tag == nil)
            #expect(r.rest == t)
        }
    }
}
