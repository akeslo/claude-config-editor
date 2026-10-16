// Draws Resources/AppIcon.icns: run `swift Resources/make-icon.swift` after changing it.
// Three stacked sheets are the user/project/local scopes; the top one shows settings with one switched on.
import AppKit
let size = 1024.0
func hex(_ v: Int, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255, alpha: a)
}
func rounded(_ r: NSRect, _ radius: Double) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = size * 0.1, tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = rounded(tile, tile.width * 0.225)
    NSGradient(starting: hex(0x174652), ending: hex(0x0F2F38))!.draw(in: tilePath, angle: -90)

    tilePath.addClip()
    // Sheets step up and right, back to front: most specific scope on top.
    let w = 470.0, h = 560.0, step = 54.0, base = NSPoint(x: 218, y: 178)
    let sheets: [(Int, Double)] = [(0x2C6672, 2), (0x4F9A94, 1), (0xE6F2EC, 0)]
    for (color, i) in sheets {
        let r = NSRect(x: base.x + step * i, y: base.y + step * i, width: w, height: h)
        let shadow = NSShadow()
        shadow.shadowColor = hex(0x061A20, 0.45); shadow.shadowBlurRadius = 36; shadow.shadowOffset = NSSize(width: 0, height: -14)
        NSGraphicsContext.saveGraphicsState(); shadow.set(); hex(color).setFill(); rounded(r, 56).fill(); NSGraphicsContext.restoreGraphicsState()
    }

    // Top sheet: four key/value rows, the third switched on.
    let top = NSRect(x: base.x, y: base.y, width: w, height: h)
    for row in 0..<4 {
        let y = top.maxY - 120 - Double(row) * 108
        let on = row == 2
        hex(0x8FAAA6).setFill()
        rounded(NSRect(x: top.minX + 56, y: y, width: on ? 150 : 190 - Double(row % 2) * 60, height: 30), 15).fill()
        let pill = NSRect(x: top.maxX - 56 - 118, y: y - 20, width: 118, height: 70)
        (on ? hex(0xF2B33D) : hex(0xC9DCD6)).setFill(); rounded(pill, 35).fill()
        let knob = NSRect(x: on ? pill.maxX - 62 : pill.minX + 8, y: pill.minY + 8, width: 54, height: 54)
        (on ? hex(0xFFFFFF) : hex(0xF4FAF7)).setFill(); NSBezierPath(ovalIn: knob).fill()
    }
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
let iconutil = try! Process.run(URL(filePath: "/usr/bin/iconutil"), arguments: ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"])
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: set)
