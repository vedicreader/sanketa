import SwiftUI

/// Quiet visual language: SF Pro text, SF Mono chips with hairlines, one saffron accent.
public enum Theme {
    public static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let text = Font.system(size: 13.5, weight: .medium)
    static let small = Font.system(size: 12, weight: .medium)
    static let mono = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    static let snippet = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let header = Font.system(size: 12, weight: .semibold).smallCaps()
    static let pad: CGFloat = 14
    static let rowGap: CGFloat = 5
    static let sectionGap: CGFloat = 16
    static let radius: CGFloat = 5
    static let hairline = Color.primary.opacity(0.22)
    static let cardRadius: CGFloat = 10
    public static let panelSize = CGSize(width: 340, height: 520)

    static let glyphs = ["ctrl": "⌃", "opt": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]

    /// `ctrl+opt+k` → `⌃⌥K`, for menus and notes.
    public static func display(hotkey s: String) -> String {
        s.lowercased().split(separator: "+").map { glyphs[String($0)] ?? $0.uppercased() }.joined()
    }
}
