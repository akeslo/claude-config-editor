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

/// One settings file at a time: every key with an inline editor, Add key, and Reset/Delete per key.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var fileID: String = Paths.userSettings.path
    @State private var search = ""
    @State private var adding = false
    @State private var doctor: String?

    var body: some View {
        let sources = model.editableSources
        let source = sources.first { $0.id == fileID } ?? sources[0]
        let readOnly = source.scope == .managed
        let keys = source.root.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Picker("Editing", selection: $fileID) {
                    ForEach(sources) { s in Text("\(sourceLabel(s))  —  \(shortPath(s.url))").tag(s.id) }
                }
                .frame(maxWidth: 520)
                .help(Term.precedence.tooltip)
                Spacer()
                Button { adding = true } label: { Label("Add key", systemImage: "plus") }
                    .disabled(readOnly)
                    .keyboardShortcut("n")
            }
            .padding(Space.m)
            Text(readOnly ? "Managed settings are set by your organization and are read-only."
                 : "Changes save immediately (a backup is taken; Undo appears below). Precedence: managed › project local › project › user local › user.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Space.m).padding(.bottom, Space.s)
            Divider()
            if keys.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No keys in this file" : "No matching keys", systemImage: "slider.horizontal.3",
                                       description: Text(search.isEmpty ? "Use Add key to set one. Claude's defaults apply until then." : ""))
            } else {
                Form {
                    ForEach(keys, id: \.self) { key in
                        SettingRow(source: source, sources: sources, key: key, readOnly: readOnly)
                            .id("\(source.id)|\(key)|\(source.modified?.timeIntervalSince1970 ?? 0)")
                    }
                }
                .formStyle(.grouped)
            }
        }
        .searchable(text: $search, prompt: "Filter keys")
        .toolbar {
            Button("Open File") { openFile(source.url) }.disabled(!exists(source.url))
            Button("Run claude doctor") { Task { doctor = await ClaudeCLI.run(["doctor"]).output } }
                .help("Claude's own read-only diagnostics, including invalid settings files.")
        }
        .sheet(isPresented: $adding) { AddKeySheet(source: source) }
        .sheet(isPresented: Binding(get: { doctor != nil }, set: { if !$0 { doctor = nil } })) {
            VStack(alignment: .leading) {
                Text("claude doctor").font(.headline)
                ScrollView { Text(doctor ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { doctor = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding().frame(width: 640, height: 420)
        }
    }
}

private struct SettingRow: View {
    @Environment(AppModel.self) private var model
    let source: SettingsSource, sources: [SettingsSource], key: String, readOnly: Bool
    @State private var text = ""
    @State private var editingJSON = false
    @State private var confirm: String?   // "reset" or "delete"

    private var value: Any? { source.root[key] }

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                editor.disabled(readOnly)
                Menu {
                    Button("Reset to default…") { confirm = "reset" }
                    Button("Delete key…", role: .destructive) { confirm = "delete" }
                    Divider()
                    Button("Copy value") { copy(value.map(SettingsEdit.render) ?? "") }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(readOnly)
                .help("Reset or delete this key")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(key).fontWeight(.medium).help(settingTerm(key).tooltip)
                if let over = overriddenBy { Text("Overridden by \(sourceLabel(over))").font(.caption).foregroundStyle(.orange) }
            }
        }
        .onAppear { text = scalarText }
        .confirmationDialog(confirm == "delete" ? "Delete \(key)?" : "Reset \(key)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm == "delete" ? "Delete" : "Reset", role: .destructive) { write(nil, confirm == "delete" ? "Deleted \(key)" : "Reset \(key)") }
        } message: { Text("Removes \(key) from \(shortPath(source.url)). " + fallbackText + " A backup is kept; Undo appears below.") }
        .sheet(isPresented: $editingJSON) { JSONValueSheet(title: key, initial: value.map(SettingsEdit.render) ?? "") { write($0, "Edited \(key)") } }
    }

    @ViewBuilder private var editor: some View {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            Toggle("", isOn: Binding(get: { n.boolValue }, set: { write($0, "Set \(key) to \($0)") })).labelsHidden().toggleStyle(.switch)
        } else if value is JSON || value is [Any] {
            HStack {
                Text(summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Button("Edit…") { editingJSON = true }
            }
        } else {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                .font(.system(.body, design: .monospaced))
                .onSubmit { commitScalar() }
                .help("Press Return to save")
        }
    }

    private var summary: String {
        if let d = value as? JSON { return "{ \(d.keys.sorted().prefix(3).joined(separator: ", "))\(d.count > 3 ? ", …" : "") }  \(d.count) keys" }
        return "[ \((value as? [Any])?.count ?? 0) items ]"
    }

    private var scalarText: String { (value as? String) ?? value.map { "\($0)" } ?? "" }

    private func commitScalar() {
        guard text != scalarText else { return }
        let new: Any = value is NSNumber ? SettingsEdit.parse(text) : text
        write(new, "Set \(key)")
    }

    private var overriddenBy: SettingsSource? {
        guard let win = SettingsEdit.fallback(for: key, excluding: SettingsSource(scope: .user, url: URL(filePath: "/dev/null"), project: source.project, root: [:], modified: nil), in: sources.filter { $0.url != Paths.keybindings }),
              win.url != source.url, source.url != Paths.keybindings else { return nil }
        return win
    }

    private var fallbackText: String {
        guard source.url != Paths.keybindings, let f = SettingsEdit.fallback(for: key, excluding: source, in: sources.filter { $0.url != Paths.keybindings }) else {
            return "Claude's built-in default then applies."
        }
        let v = f.root[key].map(SettingsEdit.render) ?? ""
        return "Then \(sourceLabel(f)) wins: \(v.count > 80 ? String(v.prefix(80)) + "…" : v)."
    }

    private func write(_ v: Any?, _ title: String) {
        model.applyEdit(title) { try SettingsEdit.setKey(source.url, path: [key], value: v, expectedModified: .some(source.modified)) }
    }
}

private struct JSONValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String, initial: String
    let save: (Any) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.headline)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minWidth: 560, minHeight: 360)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let d = text.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) else { error = "Not valid JSON."; return }
                    save(v); dismiss()
                }.keyboardShortcut("s")
            }
        }
        .padding(Space.l)
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
            if source.root[key] != nil { Text("\(key) already exists; this replaces it.").foregroundStyle(.orange).font(.caption) }
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
    @State private var selection = Set<PermissionRule.ID>()
    @State private var showProjectApprovals = false
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\PermissionRule.kind)]
    @State private var editing: RuleDraft?
    @State private var deleting: [PermissionRule] = []

    var body: some View {
        let rules = model.snapshot.permissions.filter { showProjectApprovals || $0.kind != "allowedTools" }
            .filter { search.isEmpty || $0.rule.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) || $0.kind.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        let picked = rules.filter { selection.contains($0.id) && editable($0) }
        Table(rules, selection: $selection, sortOrder: $sort) {
            TableColumn("Type", value: \.kind) { r in
                Text(r.kind).foregroundStyle(r.kind == "deny" ? .red : r.kind == "ask" ? .orange : .primary)
                    .help(r.kind == "allowedTools" ? Term.allowedTools.tooltip : "\(r.kind): " + Term.permissions.tooltip)
            }.width(90)
            TableColumn("Rule", value: \.rule) { Text($0.rule).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            TableColumn("Source", value: \.source) { r in Text(r.source).help(shortPath(r.sourceURL)) }.width(200)
        }
        .searchable(text: $search, prompt: "Filter rules")
        .contextMenu(forSelectionType: PermissionRule.ID.self) { ids in
            let rs = rules.filter { ids.contains($0.id) && editable($0) }
            if rs.count == 1, let r = rs.first {
                Button("Edit…") { editing = RuleDraft(original: r, kind: r.kind, rule: r.rule, file: r.sourceURL) }
                Menu("Move to") {
                    ForEach(["allow", "ask", "deny"].filter { $0 != r.kind }, id: \.self) { k in
                        Button(k) { move(r, to: k) }
                    }
                }
            }
            if !rs.isEmpty { Button(rs.count == 1 ? "Delete…" : "Delete \(rs.count) Rules…", role: .destructive) { deleting = rs } }
        } primaryAction: { ids in
            if let r = rules.first(where: { ids.contains($0.id) && editable($0) }) { editing = RuleDraft(original: r, kind: r.kind, rule: r.rule, file: r.sourceURL) }
        }
        .toolbar {
            Toggle("Per-project approvals", isOn: $showProjectApprovals).help(Term.allowedTools.tooltip)
            Button { editing = RuleDraft(original: nil, kind: "allow", rule: "", file: Paths.userSettings) } label: { Label("Add rule", systemImage: "plus") }
            if picked.count == 1, let r = picked.first {
                Button("Edit…") { editing = RuleDraft(original: r, kind: r.kind, rule: r.rule, file: r.sourceURL) }
            }
            if !picked.isEmpty { Button("Delete…", role: .destructive) { deleting = picked } }
        }
        .sheet(item: $editing) { RuleSheet(draft: $0) }
        .confirmationDialog(deleting.count == 1 ? "Delete rule \(deleting.first?.rule ?? "")?" : "Delete \(deleting.count) rules?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) { delete(deleting) }
        } message: { Text("A backup of each settings file is kept; Undo appears below.") }
        .onChange(of: selection) {
            guard selection.count == 1, let r = rules.first(where: { selection.contains($0.id) }) else { return }
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
