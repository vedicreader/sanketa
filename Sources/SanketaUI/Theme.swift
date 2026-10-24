import SwiftUI
import SanketaCore

/// Muted, box-free visual language: SF Pro text, SF Mono keys, whitespace and hairlines.
/// Saffron appears only as thin bars (tip cards, selected search row), never as text.
public enum Theme {
    public static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let text = Font.system(size: 14, weight: .medium)
    static let small = Font.system(size: 12.5, weight: .medium)
    static let keys = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let keySymbols = Font.system(size: 15, weight: .semibold)
    static let keysSmall = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    static let keySymbolsSmall = Font.system(size: 12.5, weight: .semibold)
    /// Keys never truncate or squeeze the action text below this.
    static let keyColumn: CGFloat = 64
    static let rowPad: CGFloat = 1.5
    static let snippet = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let header = Font.system(size: 11.5, weight: .semibold).smallCaps()
    static let pad: CGFloat = 14
    /// height of the hidden title bar at the top of the panel, where the mark sits
    static let topStrip: CGFloat = 26
    static let rowGap: CGFloat = 7
    static let sectionGap: CGFloat = 14
    static let hairline = Color.primary.opacity(0.2)
    static let primary = Color.primary
    /// Darker than the system `.secondary` (50% label): that measures ~3.9:1 even on white, under WCAG's 4.5:1.
    static let secondary = Color.primary.opacity(0.72)
    public static let panelSize = CGSize(width: 340, height: 520)

    /// Opacity of the adaptive dimming tint over the glass (black in dark mode, white in light mode).
    public static func tintOpacity(_ t: Translucency) -> Double {
        switch t { case .low: 0.82; case .medium: 0.72; case .high: 0.3 }
    }
    /// Extra backing behind search results, on top of the panel tint, at every level.
    public static let resultsBackingOpacity = 0.6
    /// Approximate blur radius (points) of the glass style each level uses; the contrast harness models it.
    public static func blurRadius(_ t: Translucency) -> Double { t == .high ? 4 : 15 }

    static func tint(_ dark: Bool) -> Color { dark ? .black : .white }

    /// `ctrl+opt+k` → `⌃⌥K` and `ctrl+opt+f5` → `⌃⌥F5`, for menus and notes.
    public static func display(hotkey s: String) -> String { KeyNotation.display(s) }
}
