import AppKit
import ConfigCore
import SwiftUI

// Ledger: graphite neutrals from the system, one ink-blue accent for selection and focus,
// and four muted scope hues used only as a 3pt gutter rule. Text never relies on colour alone.

/// Light / dark sRGB pair that follows the window's appearance.
private func pair(_ l: UInt32, _ d: UInt32) -> Color {
    func ns(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(d) : ns(l) })
}

enum Ink {
    static let accent = pair(0x3557C5, 0x8EA6F2)
    static let warning = pair(0x8A5A00, 0xE0A93A)   // ≥4.5:1 on window and control backgrounds
    static let danger = pair(0xB3261E, 0xFF8A80)
    static let success = pair(0x2E6B3A, 0x7CC88A)
    static let user = pair(0x7A7F8C, 0x9AA0AD)
    static let project = pair(0x3F8F7A, 0x5FB89F)
    static let local = pair(0xB5852F, 0xD9A84E)
    static let managed = pair(0x9B4A5C, 0xC97A8C)
    static let plugin = pair(0x6E5BB0, 0x9F8EE0)
}

enum Gap {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
}

extension Target {
    var ink: Color { switch self { case .user: Ink.user; case .project: Ink.project; case .local: Ink.local } }
}

/// The scope gutter: a 3pt rule in the scope's hue down the leading edge of a row's first cell.
struct ScopeRule: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content.padding(.leading, Gap.s2).overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 2)
        }
    }
}

extension View {
    func scopeRule(_ color: Color) -> some View { modifier(ScopeRule(color: color)) }

    /// The one table and list look for every screen: inset rows, no zebra stripes.
    func appListStyle() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false)).listStyle(.inset(alternatesRowBackgrounds: false))
    }

    /// Filter menus above a list: menu style with room for the longest choice.
    func filterPicker(minWidth: CGFloat = 120) -> some View {
        pickerStyle(.menu).frame(minWidth: minWidth).fixedSize(horizontal: false, vertical: true)
    }
}

/// Centered loading state with one line of explanation.
struct LoadingState: View {
    let title: String
    var body: some View {
        VStack(spacing: Gap.s2) { ProgressView().controlSize(.small); Text(title).font(.callout) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
