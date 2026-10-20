import ConfigCore
import SwiftUI

/// "Move to ▸" for a row's context menu: user scope, or any known project (project or local file).
struct MoveToMenu: View {
    // Not @Environment: inside Table context menus it can be missing.
    private var model: AppModel? { AppModel.current }
    let current: Target
    var allowLocal = true
    let move: (Target) -> Void

    var body: some View {
        Menu("Move to") {
            option(.user)
            ForEach(projects, id: \.self) { p in
                Menu((p as NSString).lastPathComponent) {
                    option(.project(p))
                    if allowLocal { option(.local(p)) }
                }
            }
        }
    }

    /// Known project folders that still exist, current one first.
    private var projects: [String] {
        let all = (model?.snapshot.projects ?? []).filter(\.folderExists).map(\.path).filter { $0 != Paths.home.path }
        let cur = current.folder
        return (cur.map { [$0] } ?? []) + all.filter { $0 != cur }.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
    }

    private func option(_ t: Target) -> some View {
        Button(t.label) { move(t) }.disabled(t == current)
    }
}

/// The scope cell: plain text; the row's first cell carries the colour rule. Read-only items name their source.
struct ScopeLabel: View {
    let current: Target?
    var fixedLabel = "Managed"
    var body: some View {
        Text(current?.short ?? fixedLabel).foregroundStyle(.secondary).lineLimit(1)
            .help(current.map { "\($0.label). Right-click › Move to… to change it; you can undo." }
                  ?? (fixedLabel == "Managed" ? "Set by your organization; read-only here." : "Comes from \(fixedLabel.lowercased()); change it there."))
    }
}

extension Target? {
    /// Gutter colour for a row: its scope, or plugin/managed when it can't move.
    func ink(fixed: String) -> Color { self?.ink ?? (fixed == "Managed" ? Ink.managed : Ink.plugin) }
}
