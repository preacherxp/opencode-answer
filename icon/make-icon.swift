// Renders the pixel-art app icon layers into icon/AppIcon.icon and a preview PNG.
// Usage: swift icon/make-icon.swift <output-dir>
import AppKit

let canvas = 1024
let cell = 46  // 16 × 16 grid, 736 px, centred on the 1024 canvas
let origin = (canvas - 16 * cell) / 2

struct RGB { let r, g, b: CGFloat }
func rgb(_ hex: UInt32) -> RGB {
    RGB(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255)
}

// OpenCode TUI palette.
let peach = rgb(0xFAB283), blue = rgb(0x5C9CF5), light = rgb(0xEEEEEE)

/// Pixel map: P peach "?", B blue prompt bar, C cursor block.
let art = [
    "................",
    "................",
    "................",
    "..B..PPPP.......",
    "..B.PP..PP......",
    "..B.PP..PP......",
    "..B.....PP......",
    "..B....PP.......",
    "..B...PP...CC...",
    "..B...PP...CC...",
    "..B........CC...",
    "..B...PP...CC...",
    "..B...PP...CC...",
    "................",
    "................",
    "................",
]

func bitmap(_ size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.interpolationQuality = .none
    cg.setShouldAntialias(false)
    // Flip so row 0 of the art is the top.
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: 1, y: -1)
    draw(cg)
    ctx.flushGraphics()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The glyph: each pixel gets a hard, darker extrusion down-right for a chunky 8-bit feel.
func drawGlyph(_ cg: CGContext) {
    let depth = cell / 5
    for pass in 0..<2 {
        for (y, row) in art.enumerated() {
            for (x, ch) in row.enumerated() {
                let color: RGB
                switch ch {
                case "P": color = peach
                case "B": color = blue
                case "C": color = light
                default: continue
                }
                let shade: CGFloat = pass == 0 ? 0.42 : 1
                cg.setFillColor(red: color.r * shade, green: color.g * shade, blue: color.b * shade, alpha: 1)
                let offset = pass == 0 ? depth : 0
                cg.fill(CGRect(x: origin + x * cell + offset, y: origin + y * cell + offset, width: cell, height: cell))
            }
        }
    }
}

/// Faint dot grid on the same rhythm as the glyph's pixels, across the whole tile.
func drawGrid(_ cg: CGContext) {
    cg.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.07)
    let dot = 4
    var y = origin % cell
    while y < canvas {
        var x = origin % cell
        while x < canvas {
            cg.fill(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
            x += cell
        }
        y += cell
    }
}

func drawBackground(_ cg: CGContext) {
    let colors = [CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1), CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: canvas), options: [])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon"
let assets = "\(out)/AppIcon.icon/Assets"
try! FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)

save(bitmap(canvas, drawGlyph), "\(assets)/glyph.png")
save(bitmap(canvas, drawGrid), "\(assets)/grid.png")

// Preview in the macOS squircle-ish tile: 824 px body, ~185 px corners.
let preview = bitmap(canvas) { cg in
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    cg.setShouldAntialias(true)
    cg.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    cg.clip()
    cg.translateBy(x: 100, y: 100)
    cg.scaleBy(x: 824 / 1024, y: 824 / 1024)
    cg.setShouldAntialias(false)
    drawBackground(cg)
    drawGrid(cg)
    drawGlyph(cg)
}
save(preview, "\(out)/preview.png")
print("Wrote \(assets) and \(out)/preview.png")
