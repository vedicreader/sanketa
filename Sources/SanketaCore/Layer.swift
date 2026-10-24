import Foundation

public enum LayerKind: String { case app, terminal, shell, multiplexer, program, remote }

public struct Layer: Hashable, Identifiable {
    public var kind: LayerKind
    public var name: String
    public var packID: String?
    public var host: String?
    /// the pack context that the window title picks, such as `notebook`
    public var context: String?
    public var id: String { "\(host ?? "local")/\(packID ?? name)" }
    public init(kind: LayerKind, name: String, packID: String? = nil, host: String? = nil, context: String? = nil) {
        self.kind = kind; self.name = name; self.packID = packID; self.host = host; self.context = context
    }
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
