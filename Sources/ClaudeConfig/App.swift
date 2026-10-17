import ConfigCore
import SwiftUI

@main
struct ClaudeConfigApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Claude Config") {
            RootView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 980, minHeight: 600)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await model.rescan() } }.keyboardShortcut("r")
                Button("Toggle Explanations") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(["Overview", "What Claude Can Do", "What Claude Knows", "Housekeeping"], id: \.self) { g in
                    Section(g) {
                        ForEach(AppSection.allCases.filter { $0.group == g }) { s in
                            Label(s.rawValue, systemImage: s.symbol)
                                .badge(badge(for: s))
                                .help(s.term.tooltip)
                                .tag(s)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .navigationTitle(model.section.rawValue)
                .toolbar {
                    ToolbarItemGroup {
                        let issues = model.issues.filter { model.section == .health || $0.section == model.section }
                        if !issues.isEmpty {
                            Button { copy(Issue.aiPrompt(for: issues)) } label: { Label("Copy AI Prompt", systemImage: "doc.on.clipboard") }
                                .help(promptHelp(Issue.aiPrompt(for: issues)))
                        }
                        if model.loading || model.measuringStorage { ProgressView().controlSize(.small).help("Scanning…") }
                        Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .help("Read all config files again (⌘R)")
                        Button { model.showInspector.toggle() } label: { Label("Explanations", systemImage: "sidebar.right") }
                            .help("Show or hide the explanation panel (⌥⌘I)")
                    }
                }
                .inspector(isPresented: $model.showInspector) {
                    InfoPanel(item: model.info ?? InfoItem(model.section.rawValue, term: model.section.term))
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
        }
        .onChange(of: model.section) { model.info = nil }
        .sheet(item: $model.pendingFix) { FixSheet(pending: $0) }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .health: HealthView()
        case .context: ContextView()
        case .analytics: AnalyticsView()
        case .storage: StorageView()
        case .projects: ProjectsView()
        case .permissions: PermissionsView()
        case .mcp: MCPView()
        case .skills: ComponentsView()
        case .plugins: PluginsView()
        case .hooks: HooksView()
        case .instructions: AgentFilesView()
        case .settings: SettingsView()
        case .discover: DiscoverView()
        }
    }

    private func badge(for s: AppSection) -> Int {
        s == .health ? model.issues.filter { $0.severity >= .warning }.count : model.issues.filter { $0.section == s && $0.severity >= .warning }.count
    }
}

/// The right-hand panel: what the selected thing is and how it fits into Claude Code.
struct InfoPanel: View {
    let item: InfoItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                if item.title != item.term.title {
                    Text(item.term.title).font(.subheadline).foregroundStyle(.secondary)
                }
                if !item.facts.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                        ForEach(item.facts) { f in
                            GridRow {
                                Text(f.label).foregroundStyle(.secondary)
                                Text(f.value).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
                if let file = item.file {
                    HStack {
                        Button("Reveal in Finder") { reveal(file) }
                        if !file.hasDirectoryPath { Button("Open") { openFile(file) } }
                        TrashButton(url: file)
                    }
                    .controlSize(.small)
                }
                Divider()
                Text("How it fits into Claude Code").font(.cardTitle)
                Text(item.term.detail).fixedSize(horizontal: false, vertical: true)
                Link("Read the docs", destination: item.term.docURL)
                if let link = item.link { Link("View Source", destination: link).help(link.absoluteString) }
                if let prompt = item.prompt {
                    Button("Copy AI Prompt", systemImage: "doc.on.clipboard") { copy(prompt) }
                        .help(promptHelp(prompt))
                }
                if let text = item.text {
                    Divider()
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
