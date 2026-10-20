import ConfigCore
import SwiftUI

/// A non-Claude provider's config kind: the files `provider.paths(for:)` names that exist (folders listed one level down),
/// each editable as whole-file text through `FileEditorSheet` (ConfigWriter.writeText, backup first).
struct ProviderKindView: View {
    let provider: any Provider
    let kind: ConfigKind
    @State private var editing: EditTarget?

    private var files: [URL] {
        let fm = FileManager.default
        return provider.paths(for: kind, home: Paths.home, project: nil).flatMap { u -> [URL] in
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
            ContentUnavailableView("No \(kind.rawValue) files", systemImage: "doc",
                                   description: Text(provider.paths(for: kind, home: Paths.home, project: nil).map(\.path).joined(separator: "\n")))
        } else {
            List(files, id: \.self) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.pathComponents.suffix(2).joined(separator: "/")).lineLimit(1)
                        Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit") { editing = EditTarget(url: f) }.controlSize(.small)
                    Button("Reveal") { reveal(f) }.controlSize(.small)
                }
            }
            .sheet(item: $editing) { FileEditorSheet(url: $0.url) }
        }
    }
}
