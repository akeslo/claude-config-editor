// Draws Resources/AppIcon.icns: run `swift Resources/make-icon.swift` after changing it.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = size * 0.1, rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSColor(red: 0.80, green: 0.47, blue: 0.36, alpha: 1).setFill()
    shape.fill()
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let g = glyph.size
    glyph.draw(in: NSRect(x: (size - g.width) / 2, y: (size - g.height) / 2, width: g.width, height: g.height))
    return true
}
let set = URL(filePath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for px in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = px * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(px)x\(px)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appending(path: name))
    }
}
