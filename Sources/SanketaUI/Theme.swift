import SwiftUI
import SanketaCore

/// Muted, box-free visual language: SF Pro text, SF Mono keys, whitespace and hairlines.
/// Saffron appears only as thin bars and ticks (tip card, selected result, focused section), never as text.
public enum Theme {
    public static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let text = Font.system(size: 14, weight: .medium)
    static let small = Font.system(size: 12.5, weight: .medium)
    /// the tip card's buttons: below the keys in weight
    static let tiny = Font.system(size: 11.5, weight: .medium)
    static let keys = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let keySymbols = Font.system(size: 15, weight: .semibold)
    static let keysSmall = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    static let keySymbolsSmall = Font.system(size: 12.5, weight: .semibold)
    /// Keys never truncate or squeeze the action text below this.
    static let keyColumn: CGFloat = 64
    static let rowPad: CGFloat = 1
    static let snippet = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let header = Font.system(size: 11.5, weight: .semibold).smallCaps()
    static let pad: CGFloat = 14
    /// The top row, in the hidden title bar: the mark and the breadcrumb. The search field is `fieldGap` below it.
    static let topRow: CGFloat = 32
    static let fieldGap: CGFloat = 6
    /// with 15 pt keys, a row pitch of about 23 pt: compact, and the keys keep their size
    static let rowGap: CGFloat = 4
    static let sectionGap: CGFloat = 14
    static let hairline = Color.primary.opacity(0.2)
    static let primary = Color.primary
    /// Darker than the system `.secondary` (50% label): that measures ~3.9:1 even on white, under WCAG's 4.5:1.
    static let secondary = Color.primary.opacity(0.72)
    public static let panelSize = CGSize(width: 340, height: 520)
    /// The panel while the combo view shows: wide enough for a key and its action on one line.
    public static let comboSize = CGSize(width: 620, height: 580)
    /// the space between a combo key and its action
    static let comboKeyGap: CGFloat = 10
    static let comboRowGap: CGFloat = 6

    /// Opacity of the adaptive dimming tint over the glass (black in dark mode, white in light mode).
    public static func tintOpacity(_ t: Translucency) -> Double {
        switch t { case .low: 0.82; case .medium: 0.72; case .high: 0.3 }
    }
    /// Approximate blur radius (points) of the glass style each level uses; the contrast harness models it.
    public static func blurRadius(_ t: Translucency) -> Double { t == .high ? 4 : 15 }

    static func tint(_ dark: Bool) -> Color { dark ? .black : .white }

    /// `ctrl+opt+k` → `⌃⌥K` and `ctrl+opt+f5` → `⌃⌥F5`, for menus and notes.
    public static func display(hotkey s: String) -> String { KeyNotation.display(s) }
}
