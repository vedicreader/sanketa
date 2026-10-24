import Foundation
import CryptoKit
import SanketaCore

public enum InstallError: Error, Equatable, Sendable {
    case busy
    case badSize(String)
    case badHash(String)
    case http(String, Int)
    case noSpace(need: Int64, free: Int64)
    /// A redirect to plain http or to a host other than huggingface.co or *.hf.co.
    case redirectRefused(String)
    /// The download stopped without an HTTP answer (offline, connection lost, timeout).
    case network(String, String)

    /// A short reason for a network error, in plain words.
    static func reason(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet: "There is no network connection."
        case .networkConnectionLost: "The connection stopped."
        case .timedOut: "The server did not answer in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "Cannot connect to the server."
        default: "The download stopped."
        }
    }
}

/// Downloads a pinned model into `root/<folder>` and checks every file's size and SHA-256 once, at install. The
/// requests go to the spec's `huggingface.co` URLs and, through redirects, only to https hosts under `.hf.co` (its
/// CDN); they carry no key, no cookie and no user data. Downloaded bytes are data: never made executable, never run.
public final class ModelInstaller: @unchecked Sendable {
    public let root: URL
    let session: URLSession
    let freeSpace: @Sendable (URL) -> Int64?
    private let lock = NSLock()
    private var running = false
    static let marker = ".verified"
    static let chunk = 4 << 20

    /// `freeSpace` gives the bytes free on the volume of a folder (nil when unknown).
    public init(root: URL, session: URLSession = ModelInstaller.makeSession(),
                freeSpace: @escaping @Sendable (URL) -> Int64? = ModelInstaller.volumeFree) {
        self.root = root; self.session = session; self.freeSpace = freeSpace
    }

    /// An ephemeral session with no cookies, no stored credentials and no cache.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }

    /// https to huggingface.co or a host under .hf.co.
    static func allowed(_ u: URL?) -> Bool {
        guard let u, u.scheme?.lowercased() == "https", let h = u.host?.lowercased() else { return false }
        return h == "huggingface.co" || h.hasSuffix(".hf.co")
    }

    /// The bytes free must cover the download plus 5% or 256 MB, whichever is more. An old install stays until the
    /// new one is in place, so its space is not counted as free.
    static func needed(_ total: Int64) -> Int64 { total + max(total / 20, 256 << 20) }

    public static func volumeFree(_ u: URL) -> Int64? {
        (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    public func directory(_ spec: ModelSpec) -> URL { root.appendingPathComponent(spec.folder, isDirectory: true) }
    func partial(_ spec: ModelSpec) -> URL { root.appendingPathComponent(spec.folder + ".partial", isDirectory: true) }

    /// Every file is there with its pinned size, and `.verified` holds the revision. No hashing here.
    public func isInstalled(_ spec: ModelSpec) -> Bool {
        let d = directory(spec)
        guard let mark = try? String(contentsOf: d.appendingPathComponent(Self.marker), encoding: .utf8),
              mark.trimmingCharacters(in: .whitespacesAndNewlines) == spec.revision else { return false }
        return spec.files.allSatisfy { Self.size(of: d.appendingPathComponent($0.name)) == $0.size }
    }

    /// Downloads each file into `root/<folder>.partial/`, checks it, writes `.verified`, then renames the folder into
    /// place. Any failure or cancel removes `.partial`; a stale one from an earlier crash is cleared first.
    public func install(_ spec: ModelSpec, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try lock.withLock {
            if running { throw InstallError.busy }
            running = true
        }
        defer { lock.withLock { running = false } }
        let fm = FileManager.default, part = partial(spec), total = spec.downloadSize
        let report = Reporter(total: total, progress)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: part.path) { try fm.removeItem(at: part) }
            let need = Self.needed(total)
            if let free = freeSpace(root), free < need { throw InstallError.noSpace(need: need, free: free) }
            try fm.createDirectory(at: part, withIntermediateDirectories: false)
            report(0)
            var done: Int64 = 0
            for f in spec.files {
                try Task.checkCancellation()
                let dest = part.appendingPathComponent(f.name), base = done
                try await download(spec.url(f), name: f.name, to: dest) { report(base + min($0, f.size)) }
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
                guard Self.size(of: dest) == f.size else { throw InstallError.badSize(f.name) }
                guard try Self.sha256(of: dest) == f.sha256.lowercased() else { throw InstallError.badHash(f.name) }
                done += f.size
                report(done)
            }
            try spec.revision.write(to: part.appendingPathComponent(Self.marker), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            try promote(part, to: directory(spec))
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    /// Removes the installed folder and any stale `.partial`. Refused while an install runs.
    public func remove(_ spec: ModelSpec) throws {
        try lock.withLock { if running { throw InstallError.busy } }
        let fm = FileManager.default
        for u in [directory(spec), partial(spec)] where fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
    }

    /// Moves an old final folder aside, renames `part` into place, then deletes the old one.
    private func promote(_ part: URL, to final: URL) throws {
        let fm = FileManager.default
        var old: URL?
        if fm.fileExists(atPath: final.path) {
            let aside = root.appendingPathComponent(".\(final.lastPathComponent).old-\(UUID().uuidString)")
            try fm.moveItem(at: final, to: aside)
            old = aside
        }
        do { try fm.moveItem(at: part, to: final) } catch {
            if let old { try? fm.moveItem(at: old, to: final) }
            throw error
        }
        if let old { try? fm.removeItem(at: old) }
    }

    /// One GET with a download task; a non-200 answer throws `.http`, a refused redirect `.redirectRefused`.
    /// Cancelling the Swift task cancels the download.
    private func download(_ url: URL, name: String, to dest: URL,
                          received: @escaping @Sendable (Int64) -> Void) async throws {
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let t = session.downloadTask(with: URLRequest(url: url)) { tmp, resp, err in
                    let (cancelled, refused) = box.finish()
                    if cancelled { c.resume(throwing: CancellationError()); return }
                    if let refused { c.resume(throwing: InstallError.redirectRefused(refused)); return }
                    if let err {
                        c.resume(throwing: (err as? URLError).map { InstallError.network(name, InstallError.reason($0)) } ?? err)
                        return
                    }
                    guard let tmp, let h = resp as? HTTPURLResponse else { c.resume(throwing: InstallError.http(name, 0)); return }
                    guard h.statusCode == 200 else { c.resume(throwing: InstallError.http(name, h.statusCode)); return }
                    do { try FileManager.default.moveItem(at: tmp, to: dest); c.resume() } catch { c.resume(throwing: error) }
                }
                t.delegate = RedirectGuard(box)
                box.start(t, t.observe(\.countOfBytesReceived) { t, _ in received(t.countOfBytesReceived) })
            }
        } onCancel: { box.cancel() }
    }

    static func size(of u: URL) -> Int64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              a[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (a[.size] as? NSNumber)?.int64Value
    }

    /// Lowercase hex SHA-256, read in 4 MB chunks.
    static func sha256(of u: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: chunk), !d.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Passes on only values that grow, so late byte counts never move progress back.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = -1
    let total: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    init(total: Int64, _ progress: @escaping @Sendable (Int64, Int64) -> Void) { self.total = total; self.progress = progress }
    func callAsFunction(_ done: Int64) {
        let grew = lock.withLock {
            guard done > last else { return false }
            last = done
            return true
        }
        if grew { progress(done, total) }
    }
}

/// The running download task, so a cancel that comes before or during it stops it.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var watch: NSKeyValueObservation?
    private var cancelled = false
    private var refused: String?

    func start(_ t: URLSessionTask, _ w: NSKeyValueObservation) {
        let stop = lock.withLock { task = t; watch = w; return cancelled }
        t.resume()
        if stop { t.cancel() }
    }
    func cancel() { lock.withLock { cancelled = true; return task }?.cancel() }
    func refuse(_ host: String) { lock.withLock { refused = host } }
    /// Ends the watch; tells whether we cancelled it and which redirect host we refused.
    func finish() -> (Bool, String?) {
        lock.withLock { watch?.invalidate(); watch = nil; task = nil; return (cancelled, refused) }
    }
}

/// Follows a redirect only to https on huggingface.co or under .hf.co; any other is refused and noted in the box.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let box: DownloadBox
    init(_ box: DownloadBox) { self.box = box }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if ModelInstaller.allowed(request.url) { completionHandler(request); return }
        box.refuse(request.url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "?")
        completionHandler(nil)
    }
}
