import AppKit
import SwiftUI

/// Primer Primitives v10 functional colors. Hex order: light, dark, light high contrast, dark high contrast.
private func dyn(_ l: UInt32, _ d: UInt32, _ lh: UInt32, _ dh: UInt32, dimDark: Bool = false) -> Color {
    func ns(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    return Color(nsColor: NSColor(name: nil) { ap in
        switch ap.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: return ns(d, dimDark ? 0.1 : 1)
        case .accessibilityHighContrastAqua: return ns(lh)
        case .accessibilityHighContrastDarkAqua: return ns(dh, dimDark ? 0.16 : 1)
        default: return ns(l)
        }
    })
}

/// A status role: `fg` for text/icons, `emphasis` for solid fills, `subtle` for tinted backgrounds, `muted` for borders.
struct PRole {
    let fg, emphasis, subtle: Color
    var muted: Color { fg.opacity(0.4) }
}

enum PColor {
    static let fg = dyn(0x1f2328, 0xe6edf3, 0x010409, 0xffffff)
    static let fgMuted = dyn(0x59636e, 0x9198a1, 0x454c54, 0xf0f3f6)
    static let onEmphasis = dyn(0xffffff, 0xffffff, 0xffffff, 0x010409)
    static let canvas = dyn(0xffffff, 0x0d1117, 0xffffff, 0x010409)
    static let canvasSubtle = dyn(0xf6f8fa, 0x151b23, 0xffffff, 0x0a0c10)
    static let border = dyn(0xd1d9e0, 0x3d444d, 0x454c54, 0x9198a1)
    static let accent = PRole(fg: dyn(0x0969da, 0x4493f8, 0x0349b4, 0x91cbff), emphasis: dyn(0x0969da, 0x1f6feb, 0x0349b4, 0x409eff),
                              subtle: dyn(0xddf4ff, 0x388bfd, 0xddf4ff, 0x388bfd, dimDark: true))
    static let success = PRole(fg: dyn(0x1a7f37, 0x3fb950, 0x055d20, 0x26a641), emphasis: dyn(0x1f883d, 0x238636, 0x055d20, 0x09b43a),
                               subtle: dyn(0xdafbe1, 0x2ea043, 0xdafbe1, 0x2ea043, dimDark: true))
    static let attention = PRole(fg: dyn(0x9a6700, 0xd29922, 0x744500, 0xe09b13), emphasis: dyn(0x9a6700, 0x9e6a03, 0x744500, 0xb7800b),
                                 subtle: dyn(0xfff8c5, 0xbb8009, 0xfff8c5, 0xbb8009, dimDark: true))
    static let danger = PRole(fg: dyn(0xd1242f, 0xf85149, 0xa0111f, 0xff9492), emphasis: dyn(0xcf222e, 0xda3633, 0xa0111f, 0xff6a69),
                              subtle: dyn(0xffebe9, 0xf85149, 0xffebe9, 0xf85149, dimDark: true))
    static let done = PRole(fg: dyn(0x8250df, 0xab7df8, 0x6e40c9, 0xd8b9ff), emphasis: dyn(0x8250df, 0x8957e5, 0x6e40c9, 0xa371f7),
                            subtle: dyn(0xfbefff, 0xab7df8, 0xfbefff, 0xab7df8, dimDark: true))
}

enum PSpace {
    static let s0: CGFloat = 0, s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12
    static let s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 40
}

enum PRadius {
    static let small: CGFloat = 3, medium: CGFloat = 6, large: CGFloat = 12, full: CGFloat = 999
}

enum PType {
    static let title = Font.system(.title3).weight(.semibold)   // ~20pt
    static let subtitle = Font.system(.headline).weight(.semibold) // ~16pt scale
    static let body = Font.system(.body)
    static let caption = Font.system(.caption)
    static let mono = Font.system(.body, design: .monospaced)
}

enum PBorder {
    static let width: CGFloat = 1
    static let color = PColor.border
}
