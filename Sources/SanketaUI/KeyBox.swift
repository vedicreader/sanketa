import AppKit
import SanketaCore

/// The box where the user pastes an API key. Opened only from the status-menu item "OpenAI Key…".
@MainActor public enum KeyBox {
    /// "OpenAI Key" for OpenAI, else the provider's host.
    static func title(host: String) -> String { host == "api.openai.com" ? "OpenAI Key" : "API key for \(host)" }

    /// Shows the box and gives the typed text, or nil on Cancel. Focus goes back to the previous app after.
    /// Shows the box at once and gives the typed text, or nil on Cancel. A line under the field says "Looking for a
    /// key…" until `status` answers; then it shows that answer (for example, that the shell sets the key), or goes
    /// empty. Focus goes back to the previous app after.
    public static func ask(host: String, status: @escaping @Sendable () async -> String?) -> String? {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        let alert = NSAlert()
        alert.messageText = title(host: host)
        alert.informativeText = "Paste your API key for \(host). Sanketa keeps it in your Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        let line = NSTextField(wrappingLabelWithString: lookingForKey)
        line.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        line.textColor = .secondaryLabelColor
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        box.addSubview(field)
        box.addSubview(line)
        alert.accessoryView = box
        alert.window.initialFirstResponder = field
        // the answer comes back through the run loop in the common modes, which include the modal mode of the box
        Task.detached {
            let text = await status() ?? ""
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { line.stringValue = text } }
        }
        NSApp.activate()
        let answer = alert.runModal()
        previous?.activate()
        return answer == .alertFirstButtonReturn ? field.stringValue : nil
    }

    public static let lookingForKey = "Looking for a key…"

    /// The line under the field once the lookup is done. A key from the environment or the shell wins over the
    /// Keychain, so the box says so.
    public nonisolated static func statusText(_ source: KeySource?, varName: String) -> String {
        switch source {
        case .environment, .shell:
            "Your shell sets \(varName). Sanketa uses that key first. It uses a key that you save here only when \(varName) is empty."
        case .keychain: "Your Keychain has a key for this server. A new key replaces it."
        case nil: "Sanketa found no key."
        }
    }

    /// One message with an OK button, after the user chose "OpenAI Key…".
    public static func tell(_ title: String, _ text: String) {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
        previous?.activate()
    }
}
