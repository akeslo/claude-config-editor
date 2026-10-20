import SwiftUI

enum PButtonStyleKind { case primary, normal, danger, invisible }

struct PButtonStyle: ButtonStyle {
    var kind: PButtonStyleKind = .normal
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration c: Configuration) -> some View {
        let fg: Color = switch kind {
        case .primary: PColor.onEmphasis
        case .danger: PColor.danger.fg
        case .invisible: PColor.fgMuted
        case .normal: PColor.fg
        }
        c.label.font(PType.body.weight(.medium)).foregroundStyle(fg)
            .padding(.horizontal, PSpace.s3).padding(.vertical, PSpace.s1 + 1)
            .background(RoundedRectangle(cornerRadius: PRadius.medium).fill(bg(pressed: c.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: PRadius.medium)
                .stroke(kind == .primary || kind == .invisible ? .clear : PBorder.color, lineWidth: PBorder.width))
            .opacity(enabled ? 1 : 0.5)
    }

    private func bg(pressed: Bool) -> Color {
        switch kind {
        case .primary: PColor.accent.emphasis.opacity(pressed ? 0.8 : 1)
        case .invisible: pressed ? PColor.canvasSubtle : .clear
        default: pressed ? PColor.border.opacity(0.5) : PColor.canvasSubtle
        }
    }
}

/// Labelled Primer button.
struct PButton: View {
    let title: String
    var kind: PButtonStyleKind = .normal
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(PButtonStyle(kind: kind)).accessibilityLabel(title)
    }
}

/// State pill: text always shown, color is secondary.
struct PLabel: View {
    let text: String
    var role: PRole = PColor.accent
    var body: some View {
        Text(text).font(PType.caption.weight(.medium)).foregroundStyle(role.fg)
            .padding(.horizontal, PSpace.s2).padding(.vertical, 1)
            .background(Capsule().fill(role.subtle))
            .overlay(Capsule().stroke(role.muted, lineWidth: PBorder.width))
            .accessibilityLabel(text)
    }
}

struct PCounter: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(PType.caption.weight(.medium)).monospacedDigit().foregroundStyle(PColor.fg)
            .padding(.horizontal, PSpace.s2 - 2).padding(.vertical, 1)
            .background(Capsule().fill(PColor.border.opacity(0.5)))
            .accessibilityLabel("\(count)")
    }
}

enum PFlashKind {
    case info, success, warning, danger
    var role: PRole {
        switch self {
        case .info: PColor.accent
        case .success: PColor.success
        case .warning: PColor.attention
        case .danger: PColor.danger
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        }
    }
}

/// Inline banner (replaces toast styling). Icon plus text, so color is never the only signal.
struct PFlash: View {
    let text: String
    var kind: PFlashKind = .info
    var body: some View {
        HStack(alignment: .top, spacing: PSpace.s2) {
            Image(systemName: kind.symbol).foregroundStyle(kind.role.fg)
            Text(text).font(PType.body).foregroundStyle(PColor.fg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PSpace.s3)
        .background(RoundedRectangle(cornerRadius: PRadius.medium).fill(kind.role.subtle))
        .overlay(RoundedRectangle(cornerRadius: PRadius.medium).stroke(kind.role.muted, lineWidth: PBorder.width))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// Border box with optional header; rows go in the content (add `Divider()` between).
struct PBox<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(PType.subtitle).foregroundStyle(PColor.fg)
                    .padding(PSpace.s3).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PColor.canvasSubtle)
                    .accessibilityAddTraits(.isHeader)
                Divider()
            }
            content.padding(PSpace.s3)
        }
        .background(PColor.canvas)
        .clipShape(RoundedRectangle(cornerRadius: PRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: PRadius.medium).stroke(PBorder.color, lineWidth: PBorder.width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "Box")
    }
}

/// Empty state with one action.
struct PBlankslate: View {
    let title: String
    var detail: String?
    var symbol = "tray"
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: PSpace.s3) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(PColor.fgMuted)
            Text(title).font(PType.title).foregroundStyle(PColor.fg)
            if let detail { Text(detail).font(PType.body).foregroundStyle(PColor.fgMuted).multilineTextAlignment(.center) }
            if let actionTitle, let action { PButton(title: actionTitle, kind: .primary, action: action) }
        }
        .padding(PSpace.s6).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Segmented switcher (scope picker).
struct PSegmented<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button(options[i].label) { selection = options[i].value }
                    .buttonStyle(.plain).font(PType.body.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? PColor.onEmphasis : PColor.fg)
                    .padding(.horizontal, PSpace.s3).padding(.vertical, PSpace.s1)
                    .background(on ? PColor.accent.emphasis : .clear)
                    .accessibilityLabel(options[i].label)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: PRadius.medium).stroke(PBorder.color, lineWidth: PBorder.width))
    }
}
