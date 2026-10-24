import AppKit

// Test helper: a plain AppKit app whose window titles come from stdin, so tests can watch real title changes.
// Commands, one per line:
//   title TEXT        set the title of the newest window
//   window TEXT       open a new window with this title and make it key
//   set N TEXT        set the title of window N (0 = first)
//   front N           make window N key
//   tick MS TEXT      every MS ms set the newest window's title to TEXT with each `#` replaced by a count
// End of input quits. It prints "ok" after each command.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var windows: [NSWindow] = []
var ticker: Timer?

func window(_ title: String) {
    let w = NSWindow(contentRect: NSRect(x: 60 + windows.count * 40, y: 60, width: 320, height: 80),
                     styleMask: [.titled], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = title
    windows.append(w)
    w.makeKeyAndOrderFront(nil)
    app.activate()
}

func handle(_ line: String) {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let arg = parts.count > 1 ? parts[1] : ""
    switch parts.first ?? "" {
    case "title": windows.last?.title = arg
    case "window": window(arg)
    case "set":
        let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
        if let i = Int(p.first ?? ""), windows.indices.contains(i) { windows[i].title = p.count > 1 ? p[1] : "" }
    case "front": if let i = Int(arg), windows.indices.contains(i) { windows[i].makeKeyAndOrderFront(nil); app.activate() }
    case "tick":
        let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let ms = Double(p.first ?? "") ?? 50, text = p.count > 1 ? p[1] : "tick"
        var n = 0
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { _ in n += 1; windows.last?.title = text.replacingOccurrences(of: "#", with: "\(n)") }
    default: break
    }
    print("ok"); fflush(stdout)
}

window(CommandLine.arguments.dropFirst().first ?? "host")
Thread {
    while let line = readLine() { DispatchQueue.main.async { handle(line) } }
    DispatchQueue.main.async { exit(0) }
}.start()
print("ready"); fflush(stdout)
app.run()
