import Foundation

/// Calls `onChange` when the file at `url` is written in place, replaced by a rename, created or removed.
/// Watches the file (re-opened after every event, since a replace makes a new inode) and its folder.
public final class FileWatcher: @unchecked Sendable {
    let url: URL
    let onChange: () -> Void
    let callbackQueue: DispatchQueue
    let queue = DispatchQueue(label: "dev.sanketa.filewatch")
    var dir: DispatchSourceFileSystemObject?
    var file: DispatchSourceFileSystemObject?
    var pending: DispatchWorkItem?

    public init(url: URL, callbackQueue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.url = url; self.callbackQueue = callbackQueue; self.onChange = onChange
        queue.sync {
            dir = source(url.deletingLastPathComponent().path, [.write]) { [weak self] in self?.changed() }
            watchFile()
        }
    }

    deinit { dir?.cancel(); file?.cancel() }

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
        file = source(url.path, [.write, .extend, .delete, .rename, .attrib]) { [weak self] in self?.changed() }
    }

    /// Re-arms on the current inode and reports once per burst of events (an editor's save is several).
    func changed() {
        watchFile()
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self.map { s in s.callbackQueue.async { s.onChange() } } }
        pending = w
        queue.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
}
