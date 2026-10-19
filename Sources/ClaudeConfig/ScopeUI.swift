import ConfigCore
import SwiftUI

/// The scope cell used on every screen: a compact menu showing where an item applies; choosing another scope moves it.
/// `current == nil` shows a read-only tag (managed, plugin, other agent).
struct ScopeMenu: View {
    @Environment(AppModel.self) private var model
    let current: Target?
    /// Shown when `current` is nil, e.g. "Managed" or "Plugin".
    var fixedLabel = "Managed"
    var allowLocal = true
    let move: (Target) -> Void

    var body: some View {
        if let current {
            Menu {
                Section("Move to") {
                    option(.user, current)
                    ForEach(projects, id: \.self) { p in
                        Menu((p as NSString).lastPathComponent) {
                            option(.project(p), current)
                            if allowLocal { option(.local(p), current) }
                        }
                    }
                }
            } label: {
                ScopeTag(text: current.short, symbol: symbol(current))
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible).fixedSize()
            .help("\(current.label). Choose another scope to move it; you can undo.")
            .accessibilityLabel("Scope: \(current.label)")
        } else {
            ScopeTag(text: fixedLabel, symbol: fixedLabel == "Managed" ? "lock.fill" : fixedLabel == "Plugin" ? "puzzlepiece.extension" : "lock")
                .foregroundStyle(.secondary)
                .help(fixedLabel == "Managed" ? "Set by your organization; read-only here." : "Comes from \(fixedLabel.lowercased()); change it there.")
        }
    }

    /// Known project folders that still exist, current one first.
    private var projects: [String] {
        let all = model.snapshot.projects.filter(\.folderExists).map(\.path).filter { $0 != Paths.home.path }
        let cur = current?.folder
        return (cur.map { [$0] } ?? []) + all.filter { $0 != cur }.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
    }

    @ViewBuilder private func option(_ t: Target, _ current: Target) -> some View {
        Button { if t != current { move(t) } } label: {
            Label(t.label, systemImage: t == current ? "checkmark" : symbol(t))
        }
        .disabled(t == current)
    }

    private func symbol(_ t: Target) -> String {
        switch t { case .user: "person"; case .project: "folder"; case .local: "laptopcomputer" }
    }
}

/// Small scope label with an icon; same look for movable and read-only items.
struct ScopeTag: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon).font(.callout).lineLimit(1)
    }
}
