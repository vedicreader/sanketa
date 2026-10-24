import AppKit

/// The box where the user pastes an API key. Opened only from the status-menu item "OpenAI Key…".
@MainActor public enum KeyBox {
    /// Shows the box and gives the typed text, or nil on Cancel. Focus goes back to the previous app after.
    public static func ask(host: String) -> String? {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        let alert = NSAlert()
        alert.messageText = "OpenAI Key"
        alert.informativeText = "Paste your API key for \(host). Sanketa keeps it in your Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let answer = alert.runModal()
        previous?.activate()
        return answer == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
