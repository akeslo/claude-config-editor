import AppKit
import ConfigCore
import SwiftUI

// The shared bulk-selection UI: a row checkbox, the "select all visible" header box, the action bar and the keys.
// Every list screen keeps one BulkSelection and renders these.

struct BulkAction: Identifiable {
    let title: String
    var icon = ""
    var check = BulkCheck.ok
    let run: () -> Void
    var id: String { title }
}

/// Row checkbox. Plain/⌘ click toggles, ⇧ click sets the range from the last clicked row.
struct SelectBox<ID: Hashable>: View {
    @Binding var sel: BulkSelection<ID>
    let id: ID
    let visible: [ID]
    let name: String

    var body: some View {
        Toggle("Select \(name)", isOn: Binding(get: { sel.contains(id) }, set: { _ in
            sel.click(id, visible: visible, NSEvent.modifierFlags.contains(.shift) ? .range : .toggle)
        }))
        .labelsHidden().toggleStyle(.checkbox)
        .accessibilityLabel("Select \(name)")
        .help("Select \(name) (⇧-click selects a range)")
    }
}

/// Tri-state "select all visible" box.
struct SelectAllBox<ID: Hashable>: View {
    @Binding var sel: BulkSelection<ID>
    let visible: [ID]

    var body: some View {
        let h = sel.header(visible)
        Button { sel.toggleAll(visible) } label: {
            Image(systemName: h == .all ? "checkmark.square.fill" : h == .some ? "minus.square.fill" : "square")
                .foregroundStyle(h == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless).disabled(visible.isEmpty)
        .accessibilityLabel("Select all visible")
        .accessibilityValue(h == .all ? "all selected" : h == .some ? "some selected" : "none selected")
        .help(h == .all ? "Unselect all visible rows" : "Select all \(visible.count) visible rows (⌘A)")
    }
}

/// "N selected" plus the actions for the whole selection. Disabled actions say why in their tooltip.
struct BulkBar<ID: Hashable, Trailing: View>: View {
    @Binding var sel: BulkSelection<ID>
    let visible: [ID]
    let actions: [BulkAction]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.s) {
            SelectAllBox(sel: $sel, visible: visible)
            if sel.isEmpty {
                Text("Select items to act on several at once").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(sel.label(visible)).font(.callout.weight(.medium)).monospacedDigit()
                ForEach(actions) { a in
                    Button(a.title, systemImage: a.icon.isEmpty ? "circle" : a.icon, action: a.run)
                        .labelStyle(a.icon.isEmpty ? AnyLabelStyle(.titleOnly) : AnyLabelStyle(.titleAndIcon))
                        .disabled(!a.check.enabled)
                        .help(a.check.why ?? a.title)
                }
                Button("Clear") { sel.clear() }.buttonStyle(.link).help("Clear the selection (Esc)")
            }
            Spacer(minLength: 0)
            trailing()
        }
        .controlSize(.small)
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(.bar)
    }
}

extension BulkBar where Trailing == EmptyView {
    init(sel: Binding<BulkSelection<ID>>, visible: [ID], actions: [BulkAction]) {
        self.init(sel: sel, visible: visible, actions: actions) { EmptyView() }
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension View {
    /// ⌘A selects all visible rows, Space toggles the last-clicked row, Esc clears.
    func bulkKeys<ID: Hashable>(_ sel: Binding<BulkSelection<ID>>, visible: [ID]) -> some View {
        onKeyPress(keys: [.escape, .space, "a"]) { press in
            switch press.key {
            case .escape where !sel.wrappedValue.isEmpty: sel.wrappedValue.clear(); return .handled
            case .space: if let a = sel.wrappedValue.anchor { sel.wrappedValue.click(a, visible: visible) ; return .handled }; return .ignored
            case "a" where press.modifiers.contains(.command): sel.wrappedValue.selectAll(visible); return .handled
            default: return .ignored
            }
        }
    }

    /// Bar on top plus the keys: the one-line way to give a list bulk selection.
    func bulkSelectable<ID: Hashable>(_ sel: Binding<BulkSelection<ID>>, visible: [ID], actions: [BulkAction]) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { BulkBar(sel: sel, visible: visible, actions: actions); Divider() } }
            .bulkKeys(sel, visible: visible)
    }
}

/// Saves rows as CSV through a save panel.
func exportCSV(_ name: String, header: [String], rows: [[String]]) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? ([header] + rows).map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}
