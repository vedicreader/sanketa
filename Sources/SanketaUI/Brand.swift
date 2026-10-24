import AppKit

/// The Sanketa mark: a line version of the kolam icon (design/logo/sanketa-mark.svg), as a template image.
public enum Brand {
    public static let markPoints: CGFloat = 15

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
