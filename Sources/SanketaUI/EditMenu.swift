import AppKit

/// The main menu of Sanketa: an empty app menu and an Edit menu. Sanketa is an accessory app, so the menu bar never shows
/// it. AppKit finds ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z and ⇧⌘Z only in the main menu: with no main menu, the search field loses them.
/// The other text keys (⌥←, ⌘←, ⌥⌫, ⌘⌫ and ⇧ with them) come from the key bindings of the field editor.
public enum EditMenu {
    /// title, action, key; ⇧ is in the key as an upper-case letter
    public static let items: [(String, Selector, String)] = [
        ("Undo", Selector(("undo:")), "z"),
        ("Redo", Selector(("redo:")), "Z"),
        ("Cut", #selector(NSText.cut(_:)), "x"),
        ("Copy", #selector(NSText.copy(_:)), "c"),
        ("Paste", #selector(NSText.paste(_:)), "v"),
        ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ]

    @MainActor public static func make() -> NSMenu {
        let main = NSMenu()
        // AppKit takes the first item as the app menu. It has no ⌘Q, so ⌘Q in the panel never quits Sanketa by mistake
        let app = NSMenu(title: "Sanketa")
        main.addItem(withTitle: "Sanketa", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "Edit")
        for (i, (title, action, key)) in items.enumerated() {
            if i == 2 { edit.addItem(.separator()) }
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}
