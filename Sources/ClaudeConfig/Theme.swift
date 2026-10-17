import AppKit
import SwiftUI

/// One spacing scale for the whole app.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

extension Color {
    /// The teal of the app icon's card stack; lighter in dark mode so it keeps contrast.
    static let brand = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0.42, green: 0.73, blue: 0.69, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.45, blue: 0.43, alpha: 1)
    })
    /// The icon's one switched-on toggle. Used only for the figure that matters most on a page.
    static let spark = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.29, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.48, blue: 0.05, alpha: 1)
    })
}

extension Font {
    static let metric = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
    static let cardTitle = Font.headline
}

/// A dashboard card: a quiet raised surface with a hairline edge, correct in light and dark mode.
struct Card<Content: View>: View {
    var title: String?
    var source: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if title != nil || source != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.cardTitle) }
                    Spacer()
                    if let source { SourceTag(source) }
                }
            }
            content
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// Where a number comes from ("ccusage", "transcripts", "config files").
struct SourceTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text("from \(text)").font(.caption2).foregroundStyle(.tertiary)
    }
}

/// Centered loading state with one line of explanation.
struct LoadingState: View {
    let title: String
    var detail: String?
    var progress: Double?

    var body: some View {
        VStack(spacing: Space.s) {
            if let progress { ProgressView(value: progress).frame(width: 280) } else { ProgressView().controlSize(.small) }
            Text(title).font(.callout)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
