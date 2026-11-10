// Renders AppIcon.iconset PNGs: white speaker glyph on a blue macOS-style tile.
// Usage: swift make_icon.swift <output .iconset directory>
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset dir>\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
_ = NSApplication.shared

func renderPNG(pixels px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // Apple's icon grid: the tile fills 824/1024 of the canvas.
    let tile = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.28, blue: 0.86, alpha: 1),
    ])!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = glyph.size
        glyph.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in files {
    try renderPNG(pixels: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
