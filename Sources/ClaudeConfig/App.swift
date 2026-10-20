import ConfigCore
import SwiftUI

@main
struct ClaudeConfigApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Claude Config", id: "main") {
            RootView()
                .environment(model)
                .tint(Ink.accent)
                .frame(minWidth: 980, minHeight: 600)
                .task {
                    // `-appearance light|dark` on the command line forces a mode (used for screenshots of both).
                    if let a = UserDefaults.standard.string(forKey: "appearance") { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
                    await model.refresh()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await model.rescan() } }.keyboardShortcut("r")
                Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Ask Claude…") { model.showAsk = true }.keyboardShortcut("k").disabled(!model.snapshot.cliAvailable)
            }
            CommandMenu("Go") {
                ForEach(Array(Screen.sidebar(for: model.detected).first?.screens.enumerated() ?? [].enumerated()), id: \.offset) { i, scr in
                    Button(scr.title) { model.screen = scr }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Button("Backups") { model.screen = .backups }.keyboardShortcut("0")
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    /// Sidebar groups the user folded, by title; remembered across launches.
    @AppStorage("collapsedGroups") private var collapsed = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.screen) {
                ForEach(Screen.sidebar(for: model.detected), id: \.title) { g in
                    Section(isExpanded: expanded(g.title)) { ForEach(g.screens, id: \.self) { sidebarRow($0) } } header: { Text(g.title) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                if search.isEmpty {
                    detail
                } else { SearchResultsView(query: search) { search = "" } }
            }
                .appListStyle()
                .navigationTitle(search.isEmpty ? title(model.screen) : "Search")
                .toolbar {
                    ToolbarItemGroup {
                        if model.loading { ProgressView().controlSize(.small).help("Scanning…") }
                        if model.snapshot.cliAvailable {
                            Button { model.showAsk = true } label: { Label("Ask Claude", systemImage: "questionmark.bubble") }
                                .help("Ask Claude about this screen (⌘K)")
                        }
                        Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .help("Read all config files again (⌘R)")
                        Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                            .help("Show or hide the inspector (⌥⌘I)")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { if search.isEmpty { KeyHints() } }
                .inspector(isPresented: $model.showInspector) {
                    InfoPanel(item: model.info ?? InfoItem(model.section.rawValue, term: model.section.term))
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search everything")
        .onChange(of: model.screen) { model.info = nil }
        .sheet(item: $model.pendingFix) { FixSheet(pending: $0) }
        .sheet(isPresented: $model.showAsk) { AskSheet(section: model.section) }
        .overlay(alignment: .bottom) { UndoToast() }
    }

    @ViewBuilder private var detail: some View {
        switch model.screen {
        case .backups: BackupsView()
        case .kind(let id, let kind):
            if id != .claude, let p = model.detected.first(where: { $0.0.id == id })?.0 {
                ProviderKindView(provider: p, kind: kind).id(model.screen)
            } else {
                switch model.section {
                case .skills: SkillsView()
                case .permissions: PermissionsView()
                case .mcp: MCPView()
                case .agents: ComponentsView()
                case .hooks: HooksView()
                case .instructions: AgentFilesView()
                default: SettingsView()
                }
            }
        }
    }

    private func expanded(_ group: String) -> Binding<Bool> {
        Binding(get: { !collapsed.split(separator: "\n").contains(Substring(group)) },
                set: { open in
                    var set = Set(collapsed.split(separator: "\n").map(String.init))
                    if open { set.remove(group) } else { set.insert(group) }
                    collapsed = set.sorted().joined(separator: "\n")
                })
    }

    private func title(_ s: Screen) -> String {
        guard let id = s.provider, id != .claude, let p = model.detected.first(where: { $0.0.id == id })?.0 else { return s.title }
        return "\(p.displayName) · \(s.title)"
    }

    private func sidebarRow(_ s: Screen) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(badge(for: s))
            .help(s.section.term.tooltip)
            .tag(s)
    }

    private func badge(for s: Screen) -> Int {
        // Issues come from the Claude scan only.
        guard s.provider == .claude else { return 0 }
        return model.issues.filter { $0.section == s.section && $0.severity >= .warning }.count
    }
}

/// The inspector: the selected item's name, its facts as label/value rows, advice, file actions, then its raw text.
struct InfoPanel: View {
    let item: InfoItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Gap.s3) {
                Text(item.title).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Text(item.term.tooltip).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !item.facts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(item.facts) { f in
                            HStack(alignment: .firstTextBaseline) {
                                Text(f.label).foregroundStyle(.secondary)
                                Spacer(minLength: Gap.s3)
                                Text(f.value).multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(3)
                            }
                            .font(.callout).padding(.vertical, Gap.s1)
                            Divider()
                        }
                    }
                }
                ForEach(item.notes, id: \.self) { Label($0, systemImage: "lightbulb").foregroundStyle(Ink.warning).font(.callout) }
                if let file = item.file {
                    HStack {
                        Button("Reveal in Finder") { reveal(file) }
                        if !file.hasDirectoryPath { Button("Open") { openFile(file) } }
                        TrashButton(url: file)
                    }
                    .controlSize(.small)
                }
                HStack {
                    Link("Docs", destination: item.term.docURL)
                    if let link = item.link { Link("Source", destination: link).help(link.absoluteString) }
                }
                .font(.callout)
                if let text = item.text {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(Gap.s2).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }
            .padding(Gap.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Bottom bar: the keys that work on every table, and what the scope rule colours mean.
struct KeyHints: View {
    var body: some View {
        HStack(spacing: Gap.s4) {
            ForEach([("↑↓", "move"), ("↩", "open / edit"), ("⌫", "delete"), ("⌘N", "add"), ("⌘K", "ask"), ("⌘Z", "undo")], id: \.0) { k, v in
                (Text(k).font(.system(.caption, design: .monospaced)).foregroundColor(.primary) + Text(" " + v)).font(.caption)
            }
            Spacer()
            ForEach([("User", Ink.user), ("Project", Ink.project), ("Local", Ink.local), ("Managed", Ink.managed), ("Plugin", Ink.plugin)], id: \.0) { name, c in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 3, height: 10); Text(name) }.font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Gap.s4).frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One search across every page: issues, skills, agents, MCP servers, hooks, plugins and permission rules.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    let done: () -> Void

    private struct Hit: Identifiable {
        let id = UUID()
        let section: AppSection
        let title: String
        let detail: String
    }

    private var hits: [Hit] {
        let s = model.snapshot
        var all: [Hit] = model.issues.map { Hit(section: $0.section, title: $0.title, detail: $0.subject) }
        all += s.components.map { Hit(section: $0.kind == .skill ? .skills : .agents, title: $0.name, detail: $0.description) }
        all += s.mcpServers.map { Hit(section: .mcp, title: $0.name, detail: $0.command) }
        all += s.hooks.map { Hit(section: .hooks, title: $0.event, detail: $0.command) }
        all += s.plugins.map { Hit(section: .plugins, title: $0.id, detail: $0.description) }
        all += s.permissions.map { Hit(section: .permissions, title: $0.rule, detail: "\($0.kind) · \($0.source)") }
        all += AppSection.allCases.map { Hit(section: $0, title: $0.rawValue, detail: $0.group) }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let hits = hits
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(AppSection.allCases) { sec in
                    let group = hits.filter { $0.section == sec }
                    if !group.isEmpty {
                        SwiftUI.Section(sec.rawValue) {
                            ForEach(group) { h in
                                Button { model.section = sec; done() } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.title).lineLimit(1)
                                        if !h.detail.isEmpty { Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(sec.rawValue)")
                            }
                        }
                    }
                }
            }
        }
    }
}
