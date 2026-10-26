import Foundation

/// "Open as a Markdown file": a vault document's text in a file that the default app for `.md` opens. The files go in
/// `~/Library/Caches/Sanketa/Notes`, which only this user can read. Each name comes from the shelf and the document id.
public enum VaultMarkdown {
    public static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Sanketa/Notes")
    }

    /// `<shelf>-<doc>.md`, with each character that is not a letter, a digit, `-`, `_` or `.` changed to `_`.
    static func name(shelf: String, doc: String) -> String {
        let clean = "\(shelf)-\(doc)".map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" }
        return String(String(clean).trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(120)) + ".md"
    }

    /// Writes `# <title>` and the text to the file for the document, mode 0600, in `dir` (mode 0700). Gives the file.
    public static func write(title: String, text: String, shelf: String, doc: String, in dir: URL = folder) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = dir.appendingPathComponent(name(shelf: shelf, doc: doc))
        let body = title.isEmpty || text.hasPrefix("# ") ? text : "# \(title)\n\n\(text)"
        // a new file each time, so an old file or a link in its place does not stay
        try? fm.removeItem(at: f)
        guard fm.createFile(atPath: f.path, contents: Data((body + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: f.path])
        }
        return f
    }
}
