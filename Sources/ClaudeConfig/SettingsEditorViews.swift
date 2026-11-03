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

/// What the Settings screen knows about a key: a plain name, where it belongs, one line on what it does, and choices if it has a fixed set.
struct SettingInfo {
    let label: String, section: String, blurb: String
    var options: [String] = []
}

let settingSections = ["Model & effort", "Permissions", "Hooks", "Plugins & skills", "Environment", "Interface & voice", "Other"]

let knownSettings: [String: SettingInfo] = [
    "model": .init(label: "Default model", section: "Model & effort", blurb: "Model new sessions start with.", options: ["default", "opus", "sonnet", "haiku", "opusplan"]),
    "effortLevel": .init(label: "Effort level", section: "Model & effort", blurb: "How hard the model thinks before answering.", options: ["low", "medium", "high", "xhigh", "max"]),
    "alwaysThinkingEnabled": .init(label: "Always think", section: "Model & effort", blurb: "Turn on extended thinking for every request."),
    "modelSettings": .init(label: "Model settings", section: "Model & effort", blurb: "Per-model overrides."),
    "autoMode": .init(label: "Auto mode", section: "Permissions", blurb: "Rules for running without prompts."),
    "permissions": .init(label: "Permission rules", section: "Permissions", blurb: "Tools Claude may use, must ask about, or may never use."),
    "skipDangerousModePermissionPrompt": .init(label: "Skip bypass-mode warning", section: "Permissions", blurb: "Don't confirm before entering bypass permissions mode."),
    "hooks": .init(label: "Hooks", section: "Hooks", blurb: "Commands that run on session and tool events."),
    "disableAllHooks": .init(label: "Disable all hooks", section: "Hooks", blurb: "Stop every hook from running."),
    "enabledPlugins": .init(label: "Plugins", section: "Plugins & skills", blurb: "Installed plugins and whether each is on."),
    "extraKnownMarketplaces": .init(label: "Extra marketplaces", section: "Plugins & skills", blurb: "Plugin sources beyond the official one."),
    "pluginConfigs": .init(label: "Plugin options", section: "Plugins & skills", blurb: "Settings passed to individual plugins."),
    "skillOverrides": .init(label: "Skill overrides", section: "Plugins & skills", blurb: "Skills shown by name only or turned off."),
    "env": .init(label: "Environment variables", section: "Environment", blurb: "Set for every session and the commands it runs."),
    "theme": .init(label: "Theme", section: "Interface & voice", blurb: "Terminal colors.", options: ["dark", "light", "dark-daltonized", "light-daltonized", "dark-ansi", "light-ansi"]),
    "statusLine": .init(label: "Status line", section: "Interface & voice", blurb: "Command that draws the line under the prompt."),
    "voice": .init(label: "Voice", section: "Interface & voice", blurb: "Voice input settings."),
    "outputStyle": .init(label: "Output style", section: "Interface & voice", blurb: "How responses are written."),
    "spinnerTipsEnabled": .init(label: "Spinner tips", section: "Interface & voice", blurb: "Show tips while Claude works."),
    "cleanupPeriodDays": .init(label: "Keep transcripts for", section: "Other", blurb: "Days before old session transcripts are deleted (default 30)."),
    "includeCoAuthoredBy": .init(label: "Co-authored-by line", section: "Other", blurb: "Credit Claude in commits it makes."),
    "autoUpdates": .init(label: "Auto-update", section: "Other", blurb: "Install Claude Code updates automatically."),
]

/// Friendly name for a key: the catalog label, or camelCase split into words.
func settingLabel(_ key: String) -> String {
    if let l = knownSettings[key]?.label { return l }
    let words = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
    return words.prefix(1).uppercased() + words.dropFirst()
}

func settingSection(_ key: String) -> String { knownSettings[key]?.section ?? "Other" }

/// One settings file at a time, grouped into sections. Each row names the key in plain words and edits it with a fitting control.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenFilter) private var search
    @State private var fileID: String = Paths.userSettings.path
    @State private var adding = false
    @State private var selected: String?
    @State private var editingJSON: String?

    var body: some View {
        let sources = model.editableSources
        let source = sources.first { $0.id == fileID } ?? sources[0]
        let readOnly = source.scope == .managed
        let isKeybindings = source.url == Paths.keybindings
        let keys = source.root.keys.sorted { settingLabel($0) < settingLabel($1) }.filter {
            search.isEmpty || $0.localizedCaseInsensitiveContains(search) || settingLabel($0).localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: keys) { isKeybindings ? "Keybindings" : settingSection($0) }
        List(selection: $selected) {
            ForEach(isKeybindings ? ["Keybindings"] : settingSections, id: \.self) { sec in
                if let ks = grouped[sec] {
                    Section(sec) {
                        ForEach(ks, id: \.self) { key in
                            SettingRow(source: source, key: key, readOnly: readOnly, override: overriddenBy(key, source, sources)) { editingJSON = key }
                                .id("\(source.id)|\(key)|\(source.modified?.timeIntervalSince1970 ?? 0)")
                                .tag(key)
                        }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, !readOnly {
                Button("Edit as JSON…") { editingJSON = key }
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
            if keys.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No settings in this file" : "No matching settings", systemImage: "slider.horizontal.3",
                                       description: Text(search.isEmpty ? "Add one with ⌘N. Claude's defaults apply until then." : "Try the key name, such as effortLevel."))
            }
        }
        .navigationSubtitle(shortPath(source.url))
        .toolbar {
            ToolbarItem {
                Picker("File", selection: $fileID) {
                    ForEach(sources) { s in Text(sourceLabel(s)).tag(s.id) }
                }
                .pickerStyle(.menu).fixedSize()
                .help("Which settings file to edit. Precedence: managed › project local › project › user local › user.")
            }
            ToolbarItem {
                Button { adding = true } label: { Label("Add Setting", systemImage: "plus") }
                    .disabled(readOnly).keyboardShortcut("n").help("Add a setting to this file (⌘N)")
            }
            ToolbarItem {
                Button { openFile(source.url) } label: { Label("Open in Editor", systemImage: "doc.text") }
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
        let value = source.root[key]
        // Structured keys get a collapsible outline; the "Edit JSON…" sheet stays the raw-JSON escape hatch.
        let outline = SettingsOutline.tree(key: key, value: value) ?? []
        let raw = outline.isEmpty ? "\"\(key)\": " + (value.map(SettingsEdit.render) ?? "null") : nil
        return InfoItem(key, term: settingTerm(key), facts: layers.map { (sourceLabel($0), SettingsEdit.render($0.root[key]!)) },
                        file: source.url, text: raw, outline: outline)
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

private func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

/// One setting: friendly label, raw key and description on the left, its control on the right; objects expand to a structured editor.
private struct SettingRow: View {
    private var model: AppModel? { AppModel.current }   // List rows can lose the environment
    let source: SettingsSource, key: String, readOnly: Bool, override: SettingsSource?
    let editJSON: () -> Void
    @State private var text = ""
    @State private var expanded = false

    private var value: Any? { source.root[key] }
    private var scalarText: String { (value as? String) ?? value.map { "\($0)" } ?? "" }
    private var isComplex: Bool { value is JSON || value is [Any] }

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Gap.s3) {
                if isComplex {
                    Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Collapse \(settingLabel(key))" : "Expand \(settingLabel(key))")
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Gap.s2) {
                        Text(settingLabel(key)).fontWeight(.medium)
                        Text(key).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        if let override {
                            Text("Overridden by \(sourceLabel(override))").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .foregroundStyle(Ink.warning).background(Ink.warning.opacity(0.12), in: Capsule())
                                .help("\(shortPath(override.url)) sets this too, and wins.")
                        }
                    }
                    if let b = knownSettings[key]?.blurb { Text(b).font(.callout).foregroundStyle(.secondary) }
                }
                .help(settingTerm(key).tooltip)
                Spacer(minLength: Gap.s4)
                control
            }
            if isComplex && expanded {
                ComplexEditor(key: key, value: value, readOnly: readOnly, write: writePath, editJSON: editJSON)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, Gap.s1)
        .disabled(readOnly)
        .onAppear { text = scalarText }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var control: some View {
        if isBool(value), let n = value as? NSNumber {
            Toggle(settingLabel(key), isOn: Binding(get: { n.boolValue }, set: { writePath([], $0, "Set \(key) to \($0)") }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        } else if let opts = knownSettings[key]?.options, !opts.isEmpty, let s = value as? String {
            Picker(settingLabel(key), selection: Binding(get: { s }, set: { writePath([], $0, "Set \(key) to \($0)") })) {
                ForEach(opts.contains(s) ? opts : [s] + opts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        } else if let n = value as? NSNumber, !isBool(value), n.doubleValue == n.doubleValue.rounded() {
            HStack(spacing: Gap.s1) {
                TextField(settingLabel(key), text: $text).frame(width: 60).multilineTextAlignment(.trailing)
                    .onSubmit { if let i = Int(text), i != n.intValue { writePath([], i, "Set \(key)") } }
                Stepper(settingLabel(key), value: Binding(get: { n.intValue }, set: { writePath([], $0, "Set \(key)") })).labelsHidden()
            }
        } else if isComplex {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Button("Edit JSON…", action: editJSON).controlSize(.small)
        } else {
            TextField(settingLabel(key), text: $text).frame(maxWidth: 320).font(.body.monospaced())
                .onSubmit { if text != scalarText { writePath([], value is NSNumber ? SettingsEdit.parse(text) : text, "Set \(key)") } }
                .help("Press Return to save")
        }
    }

    private var summary: String {
        // A scannable count ("4 groups · 9 hooks") where the outline knows the key.
        if let s = SettingsOutline.summary(key: key, value: value) { return s }
        if let o = value as? JSON { return o.count == 1 ? "1 entry" : "\(o.count) entries" }
        if let a = value as? [Any] { return a.count == 1 ? "1 item" : "\(a.count) items" }
        return ""
    }

    private func writePath(_ sub: [String], _ v: Any?, _ title: String) {
        model?.applyEdit(title) { try SettingsEdit.setKey(source.url, path: [key] + sub, value: v, expectedModified: .some(source.modified)) }
    }
}

/// Structured editor for object values: toggles for boolean maps (plugins), text fields for string maps (env), lists for permission rules, else read-only JSON.
private struct ComplexEditor: View {
    let key: String, value: Any?, readOnly: Bool
    let write: ([String], Any?, String) -> Void
    let editJSON: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s1) {
            if let o = value as? JSON, !o.isEmpty, o.values.allSatisfy(isBool) {
                ForEach(o.keys.sorted(), id: \.self) { k in
                    Toggle(isOn: Binding(get: { (o[k] as? Bool) ?? false }, set: { write([k], $0, "\($0 ? "Enabled" : "Disabled") \(k)") })) {
                        Text(k).font(.callout.monospaced())
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                }
            } else if let o = value as? JSON, !o.isEmpty, o.values.allSatisfy({ $0 is String }) {
                Grid(alignment: .leading, verticalSpacing: Gap.s1) {
                    ForEach(o.keys.sorted(), id: \.self) { k in
                        GridRow {
                            Text(k).font(.callout.monospaced()).foregroundStyle(.secondary)
                            StringField(label: k, initial: o[k] as? String ?? "") { write([k], $0, "Set \(key).\(k)") }
                        }
                    }
                }
            } else if key == "permissions", let o = value as? JSON {
                ForEach(["allow", "ask", "deny"], id: \.self) { kind in
                    if let rules = o[kind] as? [String], !rules.isEmpty {
                        Text("\(kind.capitalized) (\(rules.count))").font(.callout.weight(.medium))
                            .foregroundStyle(kind == "deny" ? Ink.danger : kind == "ask" ? Ink.warning : .primary)
                        ForEach(rules, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled).padding(.leading, Gap.s3) }
                    }
                }
                Text("Add, move and delete rules on the Permissions screen.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(value.map(SettingsEdit.render) ?? "").font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Gap.s2).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Text field that saves on Return.
private struct StringField: View {
    let label: String, initial: String
    let save: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField(label, text: $text).labelsHidden().font(.callout.monospaced())
            .onSubmit { if text != initial { save(text) } }
            .onAppear { text = initial }
            .help("Press Return to save")
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
    @Environment(\.screenFilter) private var search
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
