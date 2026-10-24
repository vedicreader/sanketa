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
    /// The file failed on every try; the bytes that came stay, so the next download goes on from there.
    case gaveUp(String, String, tries: Int)

    /// One line for the user.
    public var message: String {
        switch self {
        case .busy: "A download is already running."
        case .badSize(let f): "\(f) has the wrong size. Nothing was installed."
        case .badHash(let f): "\(f) has the wrong contents. Nothing was installed."
        case .http(let f, let n): "\(f): the server sent HTTP \(n)."
        case .noSpace(let need, let free): "Not enough disk space: the download needs \(need / 1_000_000) MB, and \(free / 1_000_000) MB is free."
        case .redirectRefused(let h): "The download tried to go to \(h). Sanketa stopped it."
        case .network(let f, let why): "\(f): \(why)"
        case .gaveUp(let f, let why, let n): "\(f): \(why) Sanketa tried \(n) times. Download again to go on from where it stopped."
        }
    }

    /// A stall, a lost connection or a server error can pass; a refused redirect, a 4xx answer or bad bytes do not.
    var canRetry: Bool {
        switch self {
        case .network: true
        case .http(_, let n): n >= 500 || n == 408 || n == 429
        default: false
        }
    }

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
///
/// Each file streams into `<name>.partial`. When the bytes stop for `stall` seconds or the connection drops, the file
/// is tried again after each wait in `backoff`, and goes on from its last byte with an HTTP Range request. The
/// `.partial` folder stays after a failure, so the next install goes on from there; only a cancel removes it.
public final class ModelInstaller: @unchecked Sendable {
    public let root: URL
    let session: URLSession
    let freeSpace: @Sendable (URL) -> Int64?
    let backoff: [TimeInterval]
    private let lock = NSLock()
    private var running = false
    static let marker = ".verified"
    /// The revision that a `.partial` folder is for; a folder for another revision is not used.
    static let partMarker = ".revision"
    static let chunk = 4 << 20
    /// No bytes for this long ends one try.
    public static let stall: TimeInterval = 60
    /// One try of one file may take this long in total.
    public static let resourceLimit: TimeInterval = 2 * 3600

    /// `freeSpace` gives the bytes free on the volume of a folder (nil when unknown). `backoff` is the wait before
    /// each new try of a file that failed; its count is the number of new tries.
    public init(root: URL, session: URLSession = ModelInstaller.makeSession(),
                freeSpace: @escaping @Sendable (URL) -> Int64? = ModelInstaller.volumeFree,
                backoff: [TimeInterval] = [2, 4, 8, 16]) {
        self.root = root; self.session = session; self.freeSpace = freeSpace; self.backoff = backoff
    }

    /// An ephemeral session with no cookies, no stored credentials and no cache, a stall timeout and a long total limit.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = stall
        c.timeoutIntervalForResource = resourceLimit
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
    /// place. A `.partial` folder for the same revision is used again: whole files are checked again, part files go on
    /// from their last byte. A cancel removes `.partial`; other failures keep it, without a file that failed its check.
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
            let mark = part.appendingPathComponent(Self.partMarker)
            if fm.fileExists(atPath: part.path),
               (try? String(contentsOf: mark, encoding: .utf8)) != spec.revision { try fm.removeItem(at: part) }
            let have = spec.files.reduce(Int64(0)) { n, f in
                n + min(f.size, Self.size(of: part.appendingPathComponent(f.name)) ?? Self.size(of: Self.partFile(part, f)) ?? 0)
            }
            let need = Self.needed(total - have)
            if let free = freeSpace(root), free < need { throw InstallError.noSpace(need: need, free: free) }
            if !fm.fileExists(atPath: part.path) {
                try fm.createDirectory(at: part, withIntermediateDirectories: false)
                try spec.revision.write(to: mark, atomically: true, encoding: .utf8)
            }
            report(0)
            var done: Int64 = 0
            for f in spec.files {
                try Task.checkCancellation()
                let dest = part.appendingPathComponent(f.name), base = done
                if Self.size(of: dest) == f.size, try Self.sha256(of: dest) == f.sha256.lowercased() {
                    done += f.size
                    report(done)
                    continue
                }
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                let tmp = Self.partFile(part, f)
                try await fetch(spec.url(f), file: f, to: tmp) { report(base + min($0, f.size)) }
                try fm.moveItem(at: tmp, to: dest)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
                guard Self.size(of: dest) == f.size else { try? fm.removeItem(at: dest); throw InstallError.badSize(f.name) }
                guard try Self.sha256(of: dest) == f.sha256.lowercased() else { try? fm.removeItem(at: dest); throw InstallError.badHash(f.name) }
                done += f.size
                report(done)
            }
            try spec.revision.write(to: part.appendingPathComponent(Self.marker), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            try? fm.removeItem(at: mark)
            try promote(part, to: directory(spec))
        } catch {
            if error is CancellationError { try? fm.removeItem(at: part) }
            throw error
        }
    }

    static func partFile(_ part: URL, _ f: ModelFile) -> URL { part.appendingPathComponent(f.name + ".partial") }

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

    /// Tries the file once, then once more after each wait in `backoff` while the error can pass. Each try goes on from
    /// the bytes already in `tmp`.
    private func fetch(_ url: URL, file f: ModelFile, to tmp: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        var tries = 0
        while true {
            tries += 1
            do {
                try await fetchOnce(url, file: f, to: tmp, received: received)
                return
            } catch let e as InstallError where e.canRetry {
                guard tries <= backoff.count else {
                    let why: String
                    switch e {
                    case .network(_, let w): why = w
                    case .http(_, let n): why = "The server sent HTTP \(n)."
                    default: why = e.message
                    }
                    throw InstallError.gaveUp(f.name, why, tries: tries)
                }
                try await Task.sleep(for: .seconds(backoff[tries - 1]))
            }
        }
    }

    /// One GET that streams into `tmp`. With bytes already there, it asks for the rest with `Range`; a 206 answer
    /// must start at that byte, and a 200 answer starts the file again. Cancelling the Swift task cancels the request.
    private func fetchOnce(_ url: URL, file f: ModelFile, to tmp: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var have = Self.size(of: tmp) ?? 0
        if have > f.size { try fm.removeItem(at: tmp); have = 0 }
        if have == f.size { received(have); return }
        if !fm.fileExists(atPath: tmp.path) { fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o644]) }
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var req = URLRequest(url: url)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        received(have)
        let stream = FileStream(handle: handle, name: f.name, offset: have, received: received)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                stream.done = { c.resume(with: $0) }
                let t = session.dataTask(with: req)
                t.delegate = stream
                stream.start(t)
            }
        } onCancel: { stream.cancel() }
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

/// Writes one response into the part file and ends the try. It refuses a redirect off huggingface.co / *.hf.co (and
/// keeps the Range header on one it follows), and a cancel that comes before or during the request stops it.
private final class FileStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let handle: FileHandle, name: String
    let offset: Int64
    let received: @Sendable (Int64) -> Void
    var done: ((Result<Void, Error>) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var failure: Error?
    private var written: Int64 = 0

    init(handle: FileHandle, name: String, offset: Int64, received: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle; self.name = name; self.offset = offset; self.received = received
    }

    func start(_ t: URLSessionTask) {
        let stop = lock.withLock { task = t; return cancelled }
        t.resume()
        if stop { t.cancel() }
    }

    func cancel() { lock.withLock { cancelled = true; return task }?.cancel() }

    private func fail(_ e: Error) { lock.withLock { if failure == nil { failure = e } } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard ModelInstaller.allowed(request.url) else {
            fail(InstallError.redirectRefused(request.url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "?"))
            completionHandler(nil)
            return
        }
        var next = request
        if let r = task.originalRequest?.value(forHTTPHeaderField: "Range") { next.setValue(r, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = response as? HTTPURLResponse else { fail(InstallError.http(name, 0)); completionHandler(.cancel); return }
        do {
            switch h.statusCode {
            case 206 where offset > 0:
                // "bytes <start>-<end>/<size>": it must go on from the byte we have
                let range = h.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(offset)-") else {
                    try handle.truncate(atOffset: 0)
                    throw InstallError.network(name, "The server sent the wrong part of the file.")
                }
                try handle.seek(toOffset: UInt64(offset))
                written = offset
            case 200:
                try handle.truncate(atOffset: 0)
                written = 0
            default:
                throw InstallError.http(name, h.statusCode)
            }
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            received(written)
        } catch {
            fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cancelled, failure) = lock.withLock { self.task = nil; return (self.cancelled, self.failure) }
        let r: Result<Void, Error>
        if cancelled { r = .failure(CancellationError()) }
        else if let failure { r = .failure(failure) }
        else if let e = error as? URLError { r = .failure(InstallError.network(name, InstallError.reason(e))) }
        else if let error { r = .failure(error) }
        else { r = .success(()) }
        done?(r)
        done = nil
    }
}
