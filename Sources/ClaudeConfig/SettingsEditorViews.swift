import ConfigCore
import SwiftUI

extension AppModel {
    /// Runs one Backup-snapshotting edit and records it for undo, or surfaces its error.
    func applyEdit(_ title: String, _ op: () throws -> Backup.Record?) {
        do { didAct(title, try op().map { [$0] } ?? []) } catch { actionError = error.localizedDescription }
    }

    /// Settings files you can pick on the Settings screen: every scanned settings file plus keybindings.json.
    var editableSources: [SettingsSource] {
        var all = snapshot.settings
        if !all.contains(where: { $0.url == Paths.userSettings }) {
            all.insert(SettingsSource(scope: .user, url: Paths.userSettings, project: nil, root: [:], modified: nil), at: 0)
        }
        let kb = readJSON(Paths.keybindings)
        all.append(SettingsSource(scope: .user, url: Paths.keybindings, project: nil, root: kb ?? [:], modified: modificationDate(Paths.keybindings)))
        return all
    }

    func modified(of url: URL) -> Date?? {
        guard let s = snapshot.settings.first(where: { $0.url == url }) else { return nil }
        return .some(s.modified)
    }
}

func sourceLabel(_ s: SettingsSource) -> String {
    if s.url == Paths.keybindings { return "Keybindings" }
    return s.project.map { "\(s.scope.rawValue) · \(($0 as NSString).lastPathComponent)" } ?? s.scope.rawValue
}

func settingTerm(_ key: String) -> Term {
    switch key {
    case "hooks": .hook
    case "permissions": .permissions
    case "enabledPlugins", "extraKnownMarketplaces", "pluginConfigs": .plugin
    case "skillOverrides": .skillListing
    case "cleanupPeriodDays": .cleanupPeriod
    case "env": .env
    case "statusLine": .statusLine
    case "theme": .theme
    case "mcpServers", "enableAllProjectMcpServers", "enabledMcpjsonServers": .mcpServer
    default: .settings
    }
}

// MARK: - Settings

private struct KeyRow: Identifiable { let key: String; var id: String { key } }

/// One settings file at a time, as a table: key, value (edited in place), scope, and the file that overrides it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var fileID: String = Paths.userSettings.path
    @State private var search = ""
    @State private var adding = false
    @State private var selected: String?
    @State private var editingJSON: String?

    var body: some View {
        let sources = model.editableSources
        let source = sources.first { $0.id == fileID } ?? sources[0]
        let readOnly = source.scope == .managed
        let rows = source.root.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.map(KeyRow.init)
        let rule = ScopeMove.target(ofSettings: source.url)?.ink ?? (readOnly ? Ink.managed : Ink.user)
        Table(rows, selection: $selected) {
            TableColumn("Key") { (r: KeyRow) in
                Text(r.key).fontWeight(.medium).lineLimit(1).scopeRule(rule).help(settingTerm(r.key).tooltip)
            }
            .width(min: 160, ideal: 260)
            TableColumn("Value") { (r: KeyRow) in
                ValueCell(source: source, key: r.key, readOnly: readOnly) { editingJSON = r.key }
                    .id("\(source.id)|\(r.key)|\(source.modified?.timeIntervalSince1970 ?? 0)")
            }
            .width(min: 200, ideal: 640)
            TableColumn("Scope") { (_: KeyRow) in Text(sourceLabel(source)).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn("Overridden by") { (r: KeyRow) in
                if let over = overriddenBy(r.key, source, sources) { Text(sourceLabel(over)).foregroundStyle(Ink.warning).lineLimit(1) }
            }
            .width(min: 90, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, !readOnly {
                Button("Edit Value…") { editingJSON = key }
                Button("Copy Value") { copy(source.root[key].map(SettingsEdit.render) ?? "") }
                if let from = ScopeMove.target(ofSettings: source.url) {
                    MoveToMenu(current: from) { t in model.moveScope(key, to: t) { try ScopeMove.move(settingKey: key, from: source.url, to: t) } }
                }
                Divider()
                Button("Reset to Default") { write(source, key, nil, "Reset \(key)") }
                Button("Delete Key", role: .destructive) { write(source, key, nil, "Deleted \(key)") }
            }
        } primaryAction: { keys in
            if let key = keys.first, !readOnly { editingJSON = key }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No keys in this file" : "No matching keys", systemImage: "slider.horizontal.3",
                                       description: Text(search.isEmpty ? "Add one with ⌘N. Claude's defaults apply until then." : ""))
            }
        }
        .navigationSubtitle(shortPath(source.url))
        .searchable(text: $search, prompt: "Filter keys")
        .toolbar {
            ToolbarItem {
                Picker("File", selection: $fileID) {
                    ForEach(sources) { s in Text(sourceLabel(s)).tag(s.id) }
                }
                .pickerStyle(.menu).fixedSize()
                .help("Which settings file to edit. Precedence: managed › project local › project › user local › user.")
            }
            ToolbarItem {
                Button { adding = true } label: { Label("Add Key", systemImage: "plus") }
                    .disabled(readOnly).keyboardShortcut("n").help("Add a key to this file (⌘N)")
            }
            ToolbarItem {
                Button { openFile(source.url) } label: { Label("Open File", systemImage: "doc.text") }
                    .disabled(!exists(source.url)).help("Open \(shortPath(source.url)) in your text editor")
            }
        }
        .onChange(of: selected) { model.info = selected.map { info($0, source, sources) } }
        .onChange(of: fileID) { selected = nil }
        .sheet(isPresented: $adding) { AddKeySheet(source: source) }
        .sheet(item: Binding(get: { editingJSON.map(KeyRow.init) }, set: { editingJSON = $0?.key })) { r in
            JSONValueSheet(title: r.key, initial: source.root[r.key].map(SettingsEdit.render) ?? "") { write(source, r.key, $0, "Edited \(r.key)") }
        }
    }

    /// Inspector: the key's value in every file that sets it, winner first, plus its raw JSON.
    private func info(_ key: String, _ source: SettingsSource, _ sources: [SettingsSource]) -> InfoItem {
        let layers = sources.filter { $0.url != Paths.keybindings && $0.root[key] != nil }
        let raw = "\"\(key)\": " + (source.root[key].map(SettingsEdit.render) ?? "null")
        return InfoItem(key, term: settingTerm(key), facts: layers.map { (sourceLabel($0), SettingsEdit.render($0.root[key]!)) },
                        file: source.url, text: raw)
    }

    private func write(_ source: SettingsSource, _ key: String, _ v: Any?, _ title: String) {
        model.applyEdit(title) { try SettingsEdit.setKey(source.url, path: [key], value: v, expectedModified: .some(source.modified)) }
    }
}

/// The file whose value for `key` wins over `source`, if any.
private func overriddenBy(_ key: String, _ source: SettingsSource, _ sources: [SettingsSource]) -> SettingsSource? {
    guard source.url != Paths.keybindings,
          let win = SettingsEdit.fallback(for: key, excluding: SettingsSource(scope: .user, url: URL(filePath: "/dev/null"), project: source.project, root: [:], modified: nil), in: sources.filter { $0.url != Paths.keybindings }),
          win.url != source.url else { return nil }
    return win
}

/// Value cell: a switch for booleans, an inline field for scalars (Return saves), one-line JSON for objects (double-click edits).
private struct ValueCell: View {
    private var model: AppModel? { AppModel.current }   // Table cells can lose the environment
    let source: SettingsSource, key: String, readOnly: Bool
    let editJSON: () -> Void
    @State private var text = ""

    private var value: Any? { source.root[key] }
    private var scalarText: String { (value as? String) ?? value.map { "\($0)" } ?? "" }

    var body: some View {
        Group {
            if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                Toggle("", isOn: Binding(get: { n.boolValue }, set: { write($0, "Set \(key) to \($0)") }))
                    .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(key)
            } else if value is JSON || value is [Any] {
                Text(value.map(SettingsEdit.render)?.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression) ?? "")
                    .lineLimit(1).truncationMode(.tail).help("Double-click to edit")
            } else {
                TextField(key, text: $text).labelsHidden().textFieldStyle(.plain)
                    .onSubmit {
                        guard text != scalarText else { return }
                        write(value is NSNumber ? SettingsEdit.parse(text) : text, "Set \(key)")
                    }
                    .help("Press Return to save")
            }
        }
        .font(.system(.body, design: .monospaced))
        .disabled(readOnly)
        .onAppear { text = scalarText }
    }

    private func write(_ v: Any, _ title: String) {
        model?.applyEdit(title) { try SettingsEdit.setKey(source.url, path: [key], value: v, expectedModified: .some(source.modified)) }
    }
}

private struct JSONValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String, initial: String
    let save: (Any) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            Text(title).font(.headline)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minWidth: 560, minHeight: 360)
            if let error { Text(error).foregroundStyle(Ink.danger).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let d = text.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) else { error = "Not valid JSON."; return }
                    save(v); dismiss()
                }.keyboardShortcut("s")
            }
        }
        .padding(Gap.s4)
        .onAppear { text = initial }
    }
}

private struct AddKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: SettingsSource
    @State private var key = ""
    @State private var value = ""

    var body: some View {
        Form {
            Text("Add to \(sourceLabel(source)) (\(shortPath(source.url)))").font(.headline)
            TextField("Key", text: $key, prompt: Text("e.g. model, cleanupPeriodDays"))
            TextField("Value", text: $value, prompt: Text("true, 30, opus, or JSON like {\"A\": \"1\"}"), axis: .vertical).lineLimit(1...6)
                .font(.system(.body, design: .monospaced))
            if source.root[key] != nil { Text("\(key) already exists; this replaces it.").foregroundStyle(Ink.warning).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let k = key.trimmingCharacters(in: .whitespaces)
                    model.applyEdit("Added \(k)") { try SettingsEdit.setKey(source.url, path: [k], value: SettingsEdit.parse(value), expectedModified: .some(source.modified)) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 520)
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sel = BulkSelection<UUID>()
    @State private var showProjectApprovals = false
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\PermissionRule.kind)]
    @State private var editing: RuleDraft?

    var body: some View {
        let rules = model.snapshot.permissions.filter { showProjectApprovals || $0.kind != "allowedTools" }
            .filter { search.isEmpty || $0.rule.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) || $0.kind.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(rules, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("Type", value: \PermissionRule.kind) { (r: PermissionRule) in
                Text(r.kind).scopeRule(editable(r) ? ScopeMove.target(ofSettings: r.sourceURL).ink(fixed: "Managed") : Ink.managed).foregroundStyle(r.kind == "deny" ? Ink.danger : r.kind == "ask" ? Ink.warning : .primary)
                    .help(r.kind == "allowedTools" ? Term.allowedTools.tooltip : "\(r.kind): " + Term.permissions.tooltip)
            }.width(90)
            TableColumn("Rule", value: \PermissionRule.rule) { (r: PermissionRule) in Text(r.rule).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            TableColumn("Scope", value: \PermissionRule.source) { (r: PermissionRule) in
                HStack(spacing: Gap.s2) {
                    ScopeLabel(current: editable(r) ? ScopeMove.target(ofSettings: r.sourceURL) : nil, fixedLabel: r.kind == "allowedTools" ? "Approval" : "Managed")
                    if let f = ScopeMove.target(ofSettings: r.sourceURL)?.folder { Text((f as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
                }
                .help(shortPath(r.sourceURL))
            }.width(min: 150, ideal: 200)
        }
        .searchable(text: $search, prompt: "Filter rules")
        .contextMenu(forSelectionType: PermissionRule.ID.self) { ids in
            let rs = rules.filter { ids.contains($0.id) && editable($0) }
            if rs.count == 1, let r = rs.first {
                Button("Edit…") { editing = RuleDraft(original: r, kind: r.kind, rule: r.rule, file: r.sourceURL) }
                Menu("Change Type") {
                    ForEach(["allow", "ask", "deny"].filter { $0 != r.kind }, id: \.self) { k in
                        Button(k) { move(r, to: k) }
                    }
                }
                if let from = ScopeMove.target(ofSettings: r.sourceURL) {
                    MoveToMenu(current: from) { t in model.moveScope(r.rule, to: t) { try ScopeMove.move(rule: r, to: t) } }
                }
            }
            let all = rules.filter { ids.contains($0.id) }
            if !all.isEmpty { Button("Copy") { copy(all.map { "\($0.kind)\t\($0.rule)" }.joined(separator: "\n")) } }
            if !rs.isEmpty { Divider() }
            if !rs.isEmpty { Button(rs.count == 1 ? "Delete" : "Delete \(rs.count) Rules", role: .destructive) { delete(rs) } }
        } primaryAction: { ids in
            if let r = rules.first(where: { ids.contains($0.id) && editable($0) }) { editing = RuleDraft(original: r, kind: r.kind, rule: r.rule, file: r.sourceURL) }
        }
        .toolbar {
            Toggle("Per-project approvals", isOn: $showProjectApprovals).help(Term.allowedTools.tooltip)
            Button { editing = RuleDraft(original: nil, kind: "allow", rule: "", file: Paths.userSettings) } label: { Label("Add Rule", systemImage: "plus") }
                .keyboardShortcut("n").help("Add a rule (⌘N)")
        }
        .onDeleteCommand {
            let rs = rules.filter { sel.contains($0.id) && editable($0) }
            if !rs.isEmpty { delete(rs) }
        }
        .sheet(item: $editing) { RuleSheet(draft: $0) }
        .onChange(of: sel.ids) {
            guard sel.count == 1, let r = rules.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem(r.rule, term: r.kind == "allowedTools" ? .allowedTools : .permissions,
                                  facts: [("Type", r.kind), ("Source", r.source), ("File", shortPath(r.sourceURL))], file: r.sourceURL)
        }
    }

    /// allowedTools live in ~/.claude.json per project and managed rules are read-only.
    private func editable(_ r: PermissionRule) -> Bool {
        r.kind != "allowedTools" && model.snapshot.settings.first { $0.url == r.sourceURL }?.scope != .managed
    }

    private func move(_ r: PermissionRule, to k: String) {
        model.applyEdit("Moved \(r.rule) to \(k)") { try SettingsEdit.editRule(r.sourceURL, remove: (r.kind, r.rule), add: (k, r.rule), expectedModified: model.modified(of: r.sourceURL)) }
    }

    private func delete(_ rs: [PermissionRule]) {
        // One snapshot per file, so undo restores each file as it was before the first removal.
        var records: [Backup.Record] = []
        do {
            for (url, group) in Dictionary(grouping: rs, by: \.sourceURL) {
                var first = true
                for r in group {
                    let rec = try SettingsEdit.editRule(url, remove: (r.kind, r.rule), expectedModified: first ? (model.modified(of: url)) : nil)
                    if first, let rec { records.append(rec) }
                    first = false
                }
            }
        } catch { model.actionError = error.localizedDescription }
        if !records.isEmpty { model.didAct("Deleted \(rs.count) rule\(rs.count == 1 ? "" : "s")", records) }
    }
}

struct RuleDraft: Identifiable {
    let id = UUID()
    let original: PermissionRule?
    var kind: String, rule: String, file: URL
}

private struct RuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft

    var body: some View {
        let files = model.snapshot.settings.filter { $0.scope != .managed && $0.url != Paths.keybindings }
        Form {
            Text(draft.original == nil ? "Add permission rule" : "Edit permission rule").font(.headline)
            Picker("Type", selection: $draft.kind) {
                Text("Allow: runs without asking").tag("allow")
                Text("Ask: always confirm").tag("ask")
                Text("Deny: never allowed").tag("deny")
            }
            .pickerStyle(.radioGroup)
            TextField("Rule", text: $draft.rule, prompt: Text("Bash(npm test *), Read(./src/**), mcp__server"))
                .font(.system(.body, design: .monospaced))
            Picker("Saved in", selection: $draft.file) {
                if !files.contains(where: { $0.url == Paths.userSettings }) { Text("User — \(shortPath(Paths.userSettings))").tag(Paths.userSettings) }
                ForEach(files) { s in Text("\(sourceLabel(s)) — \(shortPath(s.url))").tag(s.url) }
            }
            .disabled(draft.original != nil)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.rule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 560)
    }

    private func save() {
        let rule = draft.rule.trimmingCharacters(in: .whitespaces)
        let o = draft.original
        model.applyEdit(o == nil ? "Added \(rule)" : "Edited \(rule)") {
            try SettingsEdit.editRule(draft.file, remove: o.map { ($0.kind, $0.rule) }, add: (draft.kind, rule), expectedModified: model.modified(of: draft.file))
        }
        dismiss()
    }
}
