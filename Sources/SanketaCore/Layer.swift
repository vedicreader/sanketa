import Foundation

public enum LayerKind: String { case app, terminal, shell, multiplexer, program, remote }

public struct Layer: Hashable, Identifiable {
    public var kind: LayerKind
    public var name: String
    public var packID: String?
    public var host: String?
    /// the pack context that the window title picks, such as `notebook`
    public var context: String?
    /// why the layer got its pack, such as `match "bin/ramabana"`; for `--dump-context`
    public var reason: String?
    public var id: String { "\(host ?? "local")/\(packID ?? name)" }
    public init(kind: LayerKind, name: String, packID: String? = nil, host: String? = nil, context: String? = nil, reason: String? = nil) {
        self.kind = kind; self.name = name; self.packID = packID; self.host = host; self.context = context; self.reason = reason
    }

    /// `reason` follows from the other fields, so it takes no part in equality.
    public static func == (a: Layer, b: Layer) -> Bool {
        a.kind == b.kind && a.name == b.name && a.packID == b.packID && a.host == b.host && a.context == b.context
    }
    public func hash(into h: inout Hasher) { h.combine(kind); h.combine(name); h.combine(packID); h.combine(host); h.combine(context) }
}

public struct TerminalContext {
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public init(pid: Int32, bundleID: String, appName: String, windowTitle: String?) {
        self.pid = pid; self.bundleID = bundleID; self.appName = appName; self.windowTitle = windowTitle
    }
}

public protocol RemoteQuerying {
    func paneCommand(sshArgv: [String]) -> String?
}
