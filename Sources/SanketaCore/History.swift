import Foundation

public enum Shell: String, Codable, Hashable, Sendable, CaseIterable { case fish, bash }

public struct HistoryEntry: Hashable, Sendable {
    public var command: String
    public var when: Date?
    public var shell: Shell
    public init(command: String, when: Date? = nil, shell: Shell) { self.command = command; self.when = when; self.shell = shell }
}

/// Lines of `text`, split on `\n` at the byte level (fast on large input).
private func lines(_ text: String) -> [Substring] {
    text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }
}

public enum FishHistory {
    /// Reads fish's YAML-like history: `- cmd:` and `when:` count, everything else is ignored.
    public static func parse(_ text: String) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for line in lines(text) {
            if line.hasPrefix("- cmd: ") { out.append(HistoryEntry(command: unescape(line.dropFirst(7)), shell: .fish)) }
            else if line.hasPrefix("  when: "), !out.isEmpty, out[out.count - 1].when == nil,
                    let t = TimeInterval(line.dropFirst(8).trimmingCharacters(in: .whitespaces)) {
                out[out.count - 1].when = Date(timeIntervalSince1970: t)
            }
        }
        return out
    }

    /// One left-to-right pass: `\\` is `\`, `\n` is a new line, any other `\x` stays as it is.
    static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { out.append(c); break }
            switch n {
            case "\\": out.append("\\")
            case "n": out.append("\n")
            default: out.append(c); out.append(n)
            }
        }
        return out
    }
}

public enum BashHistory {
    /// One command per line; a `#<digits>` line dates the next command.
    public static func parse(_ text: String) -> [HistoryEntry] {
        var out: [HistoryEntry] = [], pending: Date?
        for line in lines(text) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#"), t.count > 1, t.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }), let s = TimeInterval(t.dropFirst()) {
                pending = Date(timeIntervalSince1970: s)
                continue
            }
            out.append(HistoryEntry(command: String(line), when: pending, shell: .bash))
            pending = nil
        }
        return out
    }
}

public enum HistoryFile {
    /// The last `maxBytes` of the file, from a line start. nil when the file is missing or unreadable.
    public static func readTail(_ url: URL, maxBytes: Int = 4_000_000) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let truncated = size > UInt64(maxBytes)
        guard (try? fh.seek(toOffset: truncated ? size - UInt64(maxBytes) : 0)) != nil,
              var data = try? fh.readToEnd() else { return nil }
        if truncated { data = Data(data.drop(while: { $0 != 10 }).dropFirst()) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Parsed history of both shells, re-read only when a file's modification date or size changes.
public final class HistoryCache: @unchecked Sendable {
    private struct Stamp: Equatable { var mtime: Date; var size: Int }
    private struct Slot { var stamp: Stamp; var entries: [HistoryEntry] }
    private let lock = NSLock()
    private var slots: [URL: Slot] = [:]
    private var last: [HistoryEntry]?
    private var gen = 0

    public init() {}

    public private(set) var generation: Int {
        get { lock.lock(); defer { lock.unlock() }; return gen }
        set { lock.lock(); gen = newValue; lock.unlock() }
    }

    public func entries(fish: URL?, bash: URL?, maxEntries: Int) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        slots = slots.filter { $0.key == fish || $0.key == bash }
        let all = [(fish, Shell.fish), (bash, .bash)].flatMap { u, s in u.map { Array(read($0, s).suffix(max(0, maxEntries))) } ?? [] }
        if all != last { last = all; gen += 1 }
        return all
    }

    private func read(_ url: URL, _ shell: Shell) -> [HistoryEntry] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let n = a[.size] as? Int else { slots[url] = nil; return [] }
        let stamp = Stamp(mtime: m, size: n)
        if let s = slots[url], s.stamp == stamp { return s.entries }
        let es = HistoryFile.readTail(url).map { shell == .fish ? FishHistory.parse($0) : BashHistory.parse($0) } ?? []
        slots[url] = Slot(stamp: stamp, entries: es)
        return es
    }
}
