import AppKit
import CoreText

/// The Sanketa mark: a line version of the kolam icon (design/logo/sanketa-mark.svg), as a template image.
public enum Brand {
    public static let markPoints: CGFloat = 18

    /// `Bundle.main.resourceURL/Brand` in the app; `<repo>/Resources/Brand` under `swift run` and in tests.
    public static func directory() -> URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Brand"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("sanketa-mark.png").path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Brand")
    }

    /// The 1x, 2x and 3x PNGs as one image of `markPoints` points; nil when no file loads.
    public static func mark(in dir: URL = directory()) -> NSImage? {
        let img = NSImage(size: NSSize(width: markPoints, height: markPoints))
        for suffix in ["", "@2x", "@3x"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("sanketa-mark\(suffix).png")),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = img.size
            img.addRepresentation(rep)
        }
        guard !img.representations.isEmpty else { return nil }
        img.isTemplate = true
        return img
    }
}

/// A view that mouse clicks pass through, so dragging the panel by it still moves the panel.
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSFont {
    /// The same font with lower case drawn as small capitals.
    func withSmallCaps() -> NSFont {
        let d = fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector]]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
