import AppKit

/// Menu bar version of the app icon: prompt bar and pixel "?", plus a block cursor while questions wait.
/// Same art as icon/make-icon.swift, cropped to the glyph.
enum PixelIcon {
    private static let art = [
        "B..PPPP.....",
        "B.PP..PP....",
        "B.PP..PP....",
        "B.....PP....",
        "B....PP.....",
        "B...PP...CC.",
        "B...PP...CC.",
        "B........CC.",
        "B...PP...CC.",
        "B...PP...CC.",
    ]

    /// 1.5 pt cells land on whole pixels on Retina screens (3 px), so edges stay crisp.
    private static let cell: CGFloat = 1.5

    static func menuBar(waiting: Bool) -> NSImage {
        let columns = waiting ? art[0].count : 8
        let size = NSSize(width: CGFloat(columns) * cell, height: CGFloat(art.count) * cell)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in art.enumerated() {
                for (x, ch) in row.enumerated() where x < columns && ch != "." {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = waiting ? "OpenCode questions waiting" : "OpenCode questions"
        return image
    }
}
