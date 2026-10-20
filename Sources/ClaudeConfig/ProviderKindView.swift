import ConfigCore
import SwiftUI

/// A non-Claude provider's config kind: the files `provider.paths(for:)` names that exist (folders listed one level down),
/// each editable as whole-file text through `FileEditorSheet` (ConfigWriter.writeText, backup first).
struct ProviderKindView: View {
    let provider: any Provider
    let kind: ConfigKind
    @State private var editing: EditTarget?
    @State private var selected: String?

    private var files: [URL] {
        let fm = FileManager.default
        return Screen.kinds(shownOn: kind).flatMap { provider.paths(for: $0, home: Paths.home, project: nil) }.flatMap { u -> [URL] in
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { return [] }
            guard dir.boolValue else { return [u] }
            let kids = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            // A skill is a folder; show its SKILL.md.
            return kids.map { k in exists(k.appending(path: "SKILL.md")) ? k.appending(path: "SKILL.md") : k }
                .filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
        }
    }

    var body: some View {
        let files = files
        if files.isEmpty {
            ContentUnavailableView("No files yet", systemImage: "doc",
                                   description: Text(Screen.kinds(shownOn: kind).flatMap { provider.paths(for: $0, home: Paths.home, project: nil) }.map(\.path).joined(separator: "\n")))
        } else {
            Table(files.map(EditTarget.init), selection: $selected) {
                TableColumn("File") { (f: EditTarget) in Text(f.url.pathComponents.suffix(2).joined(separator: "/")).fontWeight(.medium).lineLimit(1) }
                    .width(min: 160, ideal: 280)
                TableColumn("Path") { (f: EditTarget) in Text(shortPath(f.url)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                TableColumn("Modified") { (f: EditTarget) in Text(relative(modificationDate(f.url))).foregroundStyle(.secondary) }.width(min: 90, ideal: 120)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let f = files.first(where: { ids.contains($0.path) }) {
                    Button("Edit") { editing = EditTarget(url: f) }
                    Button("Open in Text Editor") { openFile(f) }
                    Button("Reveal in Finder") { reveal(f) }
                }
            } primaryAction: { ids in
                if let f = files.first(where: { ids.contains($0.path) }) { editing = EditTarget(url: f) }
            }
            .sheet(item: $editing) { FileEditorSheet(url: $0.url) }
        }
    }
}
