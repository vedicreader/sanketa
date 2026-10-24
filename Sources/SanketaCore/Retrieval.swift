import Foundation

/// Loose matching of a natural-language request to pack entries; it gives the model its candidates.
public enum Retrieval {
    static let stopwords: Set<String> = ["a", "an", "the", "how", "do", "does", "i", "to", "in", "of", "for", "with", "my",
                                         "me", "what", "is", "are", "can", "you", "show", "find", "get", "make", "on", "it",
                                         "this", "that", "and", "or", "way", "want"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Strips one of `ing ed es s` (the stem keeps 3 or more characters), then a doubled final consonant.
    /// `es` comes off only after s, x, z, ch or sh, and `s` never comes off after another s.
    static func stem(_ w: String) -> String {
        var s = w
        for suf in ["ing", "ed", "es", "s"] where s.hasSuffix(suf) && s.count - suf.count >= 3 {
            let base = String(s.dropLast(suf.count))
            if suf == "es", !["s", "x", "z", "ch", "sh"].contains(where: base.hasSuffix) { continue }
            if suf == "s", base.hasSuffix("s") { break }
            s = base; break
        }
        if s.count > 3, let last = s.last, s.dropLast().last == last, last.isLetter, !"aeiou".contains(last) { s.removeLast() }
        return s
    }

    public static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).filter { !stopwords.contains($0) }.map(stem).filter { seen.insert($0).inserted }
    }

    static func termScore(_ t: String, _ item: SearchItem, titleStems: [String], title: String) -> Int {
        if titleStems.contains(where: { $0.hasPrefix(t) }) { return 3 }
        if title.contains(t) { return 2 }
        let rest = [item.detail, item.explain ?? "", item.packName] + item.tags
        return rest.contains { $0.lowercased().contains(t) } ? 1 : 0
    }

    /// Items that share a word with `query`, best first; ties go to the innermost context pack.
    public static func candidates(_ query: String, _ items: [SearchItem], context: [String], limit: Int = 40) -> [SearchItem] {
        let ts = terms(query)
        guard !ts.isEmpty else { return [] }
        let rankOf = { (i: SearchItem) in context.firstIndex(of: i.packID) ?? Int.max }
        let scored: [(i: Int, item: SearchItem, score: Int)] = items.enumerated().compactMap { o in
            let title = o.element.title.lowercased()
            let stems = words(title).map(stem)
            let s = ts.reduce(0) { $0 + termScore($1, o.element, titleStems: stems, title: title) }
            guard s > 0 else { return nil }
            return (o.offset, o.element, s + (context.contains(o.element.packID) ? 1 : 0) + (o.element.active ? 1 : 0))
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let (ra, rb) = (rankOf(a.item), rankOf(b.item))
            if ra != rb { return ra < rb }
            return a.i < b.i
        }.prefix(limit).map(\.item)
    }
}

/// The bench prompt: a numbered list of candidate entries the model must choose from.
public struct ChoicePrompt: Equatable, Sendable {
    public enum Task: Equatable, Sendable { case search(String), suggest([String]) }

    public var task: Task
    public var refs: [String]
    public var lines: [String]
    public var maxPicks: Int

    public init(task: Task, refs: [String], lines: [String], maxPicks: Int) {
        self.task = task; self.refs = refs; self.lines = lines; self.maxPicks = maxPicks
    }

    public var instructions: String {
        "You match a request to entries from a list of keyboard shortcuts and command tips. Answer only with refs from the list, best first, at most \(maxPicks). Return an empty list if nothing fits."
    }

    static let answerLine = "\nAnswer with JSON only: {\"picks\": [...]}, where picks is a list of ref strings from the Entries list."

    public var userText: String {
        let entries = lines.joined(separator: "\n")
        switch task {
        case .search(let q): return "Request: \(q)\nEntries:\n" + entries + Self.answerLine
        case .suggest(let cmds):
            return "Recent commands:\n" + cmds.joined(separator: "\n") + "\nPick entries that would help with what these commands do.\nEntries:\n"
                + entries + Self.answerLine
        }
    }

    /// The first half of the entries (at least one), for a model whose context is too small.
    public func halved() -> ChoicePrompt {
        let n = max(1, refs.count / 2)
        return ChoicePrompt(task: task, refs: Array(refs.prefix(n)), lines: Array(lines.prefix(n)), maxPicks: maxPicks)
    }

    public static let lineLimit = 160, commandLimit = 120, commandCount = 10

    /// Refs `e1…eN`; lines stop before their total (with new lines) passes `charBudget`.
    public static func build(task: Task, candidates: [SearchItem], maxPicks: Int, charBudget: Int = 6000)
        -> (prompt: ChoicePrompt, refs: [String: SearchItem]) {
        var refs: [String] = [], lines: [String] = [], map: [String: SearchItem] = [:], total = 0
        for (n, it) in candidates.enumerated() {
            let ref = "e\(n + 1)"
            let line = String("\(ref) | \(it.packName) | \(it.title) | \(it.detail)".prefix(lineLimit))
            if total + line.count + 1 > charBudget { break }
            total += line.count + 1
            refs.append(ref); lines.append(line); map[ref] = it
        }
        var t = task
        if case .suggest(let cmds) = task { t = .suggest(cmds.suffix(commandCount).map { String($0.prefix(commandLimit)) }) }
        return (ChoicePrompt(task: t, refs: refs, lines: lines, maxPicks: maxPicks), map)
    }
}

/// The model only names refs; this keeps the ones that are in the list.
public enum Grounding {
    /// Known refs in pick order, without repeats, at most `max`. A pick list that is only the first N refs in list
    /// order (N ≥ 2) is a model that echoed the list, not a choice, and gives nothing.
    public static func resolve(_ picks: [String], _ refs: [String: SearchItem], order: [String], max: Int) -> [SearchItem] {
        if picks.count >= 2, picks == Array(order.prefix(picks.count)) { return [] }
        var seen = Set<String>()
        return Array(picks.filter { refs[$0] != nil && seen.insert($0).inserted }.prefix(Swift.max(0, max)).compactMap { refs[$0] })
    }
}
