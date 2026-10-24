import Foundation

/// Calls `onChange` when the file at `url` is written in place, replaced by a rename, created or removed.
/// Watches the file (re-opened after every event, since a replace makes a new inode) and its folder.
/// With `children`, `url` is a folder and each of its files with that extension is watched too, so an in-place
/// save of one pack (which does not change the folder) also counts.
public final class FileWatcher: @unchecked Sendable {
    let url: URL
    let children: String?
    let delay: TimeInterval
    let onChange: () -> Void
    let callbackQueue: DispatchQueue
    let queue = DispatchQueue(label: "dev.sanketa.filewatch")
    var dir: DispatchSourceFileSystemObject?
    var file: DispatchSourceFileSystemObject?
    var kids: [DispatchSourceFileSystemObject] = []
    var pending: DispatchWorkItem?
    /// inode of `url` at the last event; the folder above reports every change in it, and only a new inode here counts.
    /// Like the sources and `pending`, it is read and written only on `queue`.
    var known: ino_t?
    static let fileEvents: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .attrib]

    public init(url: URL, children: String? = nil, delay: TimeInterval = 0.2, callbackQueue: DispatchQueue = .main,
                onChange: @escaping () -> Void) {
        self.url = url; self.children = children; self.delay = delay; self.callbackQueue = callbackQueue; self.onChange = onChange
        queue.sync {
            known = inode()
            dir = source(url.deletingLastPathComponent().path, [.write]) { [weak self] in self?.folderChanged() }
            watchFile()
        }
    }

    deinit { dir?.cancel(); file?.cancel(); kids.forEach { $0.cancel() } }

    func source(_ path: String, _ mask: DispatchSource.FileSystemEvent, _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        s.setEventHandler(handler: handler)
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    func watchFile() {
        file?.cancel()
        file = source(url.path, Self.fileEvents) { [weak self] in self?.changed() }
        guard let ext = children else { return }
        kids.forEach { $0.cancel() }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { ($0 as NSString).pathExtension == ext }
        kids = names.compactMap { source(url.appendingPathComponent($0).path, Self.fileEvents) { [weak self] in self?.changed() } }
    }

    func inode() -> ino_t? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_ino : nil
    }

    /// A save of a sibling (config.toml next to the packs folder) changes the folder above but not `url`: ignored.
    func folderChanged() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard inode() != known else { return }
        changed()
    }

    /// Re-arms on the current inodes and reports once per burst of events (an editor's save is several).
    func changed() {
        dispatchPrecondition(condition: .onQueue(queue))
        known = inode()
        watchFile()
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self.map { s in s.callbackQueue.async { s.onChange() } } }
        pending = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
