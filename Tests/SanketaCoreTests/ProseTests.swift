import Foundation
import Testing
@testable import SanketaCore

/// Flesch–Kincaid grade of the user docs (user directive: ASD-STE100, grade 9 English).
enum Readability {
    /// Vowel groups, less a silent final `e` (not `-le`), at least one per word.
    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter(\.isLetter)
        guard !w.isEmpty else { return 0 }
        let vowels = Set("aeiouy")
        var n = 0, prev = false
        for c in w { let v = vowels.contains(c); if v && !prev { n += 1 }; prev = v }
        if w.hasSuffix("e"), !w.hasSuffix("le"), n > 1 { n -= 1 }
        return max(1, n)
    }

    /// Prose only: fenced code, tables, HTML, inline code and link targets go; headings and list items end a sentence.
    static func prose(_ md: String) -> String {
        var out = [String](), fenced = false
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { fenced.toggle(); continue }
            if fenced || t.hasPrefix("|") || t.hasPrefix("<") || t.isEmpty { continue }
            var s = t.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
                .replacingOccurrences(of: #"^(#+|[-*]|\d+\.)\s+"#, with: "", options: .regularExpression)
            if t.hasPrefix("#") || t.hasPrefix("-") || t.hasPrefix("*") || t.first?.isNumber == true,
               let last = s.last, !".!?:".contains(last) { s += "." }
            out.append(s)
        }
        return out.joined(separator: " ")
    }

    static func grade(_ md: String) -> (grade: Double, words: Int, sentences: Int) {
        let text = prose(md)
        // a sentence ends at . ! ? or : followed by a space or the end, so `config.toml` or `e.g` don't split one
        let sentences = max(1, text.replacingOccurrences(of: #"[.!?:](\s|$)"#, with: "\u{1}", options: .regularExpression)
            .split(separator: "\u{1}").filter { $0.contains { $0.isLetter } }.count)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains { $0.isLetter } }
        let syl = words.map(syllables).reduce(0, +)
        let w = Double(max(1, words.count))
        return (0.39 * w / Double(sentences) + 11.8 * Double(syl) / w - 15.59, words.count, sentences)
    }
}

@Suite struct ProseTests {
    @Test func syllableCounter() {
        for (w, n) in [("cat", 1), ("table", 2), ("make", 1), ("panel", 2), ("terminal", 3), ("the", 1), ("readable", 3), ("you", 1)] {
            #expect(Readability.syllables(w) == n, "\(w)")
        }
        #expect(Readability.grade("The cat sat on the mat. The dog ran.").grade < 2)
        #expect(Readability.grade("Comprehensive internationalization considerations necessitate extraordinarily sophisticated documentation.").grade > 15)
    }

    @Test func strippingDropsCodeAndTables() {
        let md = "# Title\n\nShort words here.\n\n```sh\nincomprehensibilities --everything\n```\n\n| a | b |\n| --- | --- |\n\nUse `internationalization` now."
        #expect(Readability.prose(md) == "Title. Short words here. Use  now.")
    }

    @Test(arguments: ["README.md", "docs/packs.md"])
    func docIsGradeNineOrBelow(_ file: String) throws {
        let md = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
        let r = Readability.grade(md)
        print("Flesch–Kincaid \(file): grade \(String(format: "%.2f", r.grade)), \(r.words) words, \(r.sentences) sentences")
        #expect(r.grade <= 9.0, "\(file) is at grade \(r.grade)")
    }
}
