import UniformTypeIdentifiers
import AppKit
import ConfigCore
import SwiftUI

/// What the side panel explains: a term, plus facts about the selected item.
struct InfoItem: Equatable {
    var title: String
    var term: Term
    var facts: [Fact] = []
    var file: URL?
    var text: String?
    var prompt: String?
    var link: URL?

    struct Fact: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    init(_ title: String, term: Term, facts: [(String, String)] = [], file: URL? = nil, link: URL? = nil, text: String? = nil) {
        self.title = title
        self.term = term
        self.facts = facts.map { Fact(label: $0.0, value: $0.1) }
        self.file = file
        self.link = link
        self.text = text
    }
}

struct PendingFix: Identifiable {
    let id = UUID()
    let title: String
    let fix: Fix
}

@MainActor @Observable
final class AppModel {
    // `-section <name>` on the command line opens a given section (used for screenshots).
    var section: AppSection = UserDefaults.standard.string(forKey: "section").flatMap { AppSection(rawValue: $0) } ?? .health
    var snapshot = Snapshot()
    var storage: [StorageArea] = []
    var projectBytes: [String: Int64] = [:]
    var pluginTokens: [String: Int] = [:]
    var available: [AvailablePlugin] = []
    var loading = false
    var measuringStorage = false
    var info: InfoItem?
    var pendingFix: PendingFix?
    var showInspector = true
    var analytics: AnalyticsReport?
    var analyticsProgress = 0.0
    /// ccusage cost report, cached for the launch; nil while loading.
    var usage: Result<UsageReport, UsageError>?

    var issues: [Issue] {
        var s = snapshot
        for i in s.plugins.indices { s.plugins[i].alwaysOnTokens = pluginTokens[s.plugins[i].id] }
        for i in s.projects.indices { s.projects[i].dataBytes = projectBytes[s.projects[i].path] ?? 0 }
        return Checks.run(s, storage: storage)
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged() }
        }
    }

    func refresh() async {
        loading = true
        snapshot = await Scanner.load()
        loading = false
        Task { await measure() }
        Task { await loadPluginTokens() }
    }

    /// Re-scan when coming back to the app, since Claude may have changed things meanwhile.
    func refreshIfChanged() {
        guard !loading, modificationDate(Paths.claudeJSON) != snapshot.claudeJSONModified || Date().timeIntervalSince(snapshot.scannedAt) > 60 else { return }
        Task { await refresh() }
    }

    func measure() async {
        measuringStorage = true
        let areas = Scanner.storageAreas()
        storage = areas
        let projects = snapshot.projects
        let measured = await withTaskGroup(of: StorageArea.self) { group in
            for a in areas { group.addTask { Scanner.measure(a) } }
            var out: [StorageArea] = []
            for await a in group { out.append(a) }
            return out
        }
        storage = measured.sorted { $0.bytes > $1.bytes }
        projectBytes = await Task.detached {
            Dictionary(projects.map { ($0.path, directorySize($0.dataDir)) }, uniquingKeysWith: { a, _ in a })
        }.value
        measuringStorage = false
    }

    func loadPluginTokens() async {
        for p in snapshot.plugins where p.enabled && pluginTokens[p.id] == nil {
            pluginTokens[p.id] = await Scanner.alwaysOnTokens(plugin: p.id)
        }
    }

    func loadAvailable() async {
        if available.isEmpty { available = await Scanner.available() }
    }

    func loadAnalytics(force: Bool = false) async {
        guard force || analytics == nil else { return }
        analytics = await Analytics.load { done, total in
            Task { @MainActor in self.analyticsProgress = Double(done) / Double(max(total, 1)) }
        }
    }

    /// ⌘R and the Rescan button: config files, plus ccusage if it was already loaded.
    func rescan() async {
        if usage != nil { Task { await loadUsage(force: true) } }
        await refresh()
    }

    func loadUsage(force: Bool = false) async {
        guard force || usage == nil else { return }
        if force { usage = nil }
        usage = await CCUsage.load()
    }

    func propose(_ title: String, _ fix: Fix) { pendingFix = PendingFix(title: title, fix: fix) }
    func proposeTrash(_ url: URL) { propose("Move \(url.lastPathComponent) to the Trash", .trash([url])) }

    // MARK: Totals

    var startupBudget: [(label: String, term: Term, tokens: Int, note: String)] {
        let s = snapshot
        let userMD = s.instructions.filter { $0.project == nil && ($0.kind == .claudeMD || ($0.kind == .rule && !$0.pathScoped)) }
        let own = s.components.filter { $0.scope == .user }
        let skills = own.filter { $0.kind == .skill }.reduce(0) { $0 + $1.listingTokens }
        let agents = own.filter { $0.kind == .subagent || $0.kind == .command }.reduce(0) { $0 + $1.listingTokens }
        let plugins = s.plugins.filter(\.enabled).reduce(0) { $0 + (pluginTokens[$1.id] ?? 0) }
        let userMCP = s.mcpServers.filter { $0.scope == .user || $0.scope == .plugin }.count
        return [
            ("User CLAUDE.md & rules", .claudeMD, userMD.reduce(0) { $0 + $1.tokens }, "\(userMD.count) files, every session"),
            ("Personal skills", .skillListing, skills, "descriptions in the skill listing"),
            ("Personal subagents & commands", .subagent, agents, "descriptions"),
            ("Plugins (always-on)", .plugin, plugins, pluginTokens.isEmpty ? "measuring with claude plugin details…" : "from claude plugin details"),
            ("MCP tool names", .mcpServer, userMCP * 150, "≈150 per server, \(userMCP) user/plugin servers (rough)"),
        ]
    }

    var startupTokens: Int { startupBudget.reduce(0) { $0 + $1.tokens } }
    var diskBytes: Int64 { storage.reduce(0) { $0 + $1.bytes } + snapshot.claudeJSONBytes }
}

extension View {
    /// Tooltip on hover, from the glossary.
    func explains(_ term: Term) -> some View { help(term.tooltip) }
    /// Tooltip: what this kind of thing is, then what this one does.
    func explains(_ term: Term, _ about: String) -> some View { help(term.tooltip + (about.isEmpty ? "" : "\n\n" + about)) }
}

/// Hover text showing the exact prompt a Copy button puts on the clipboard.
func promptHelp(_ prompt: String) -> String {
    "Copies this prompt:\n\n" + (prompt.count > 1500 ? prompt.prefix(1500) + "…" : prompt)
}

/// Opens the shared confirm sheet to trash `url`; hidden for anything the refuse-list protects.
struct TrashButton: View {
    @Environment(AppModel.self) private var model
    let url: URL
    var label = "Move to Trash…"
    var body: some View {
        if trashRefusal(url) == nil { Button(label) { model.proposeTrash(url) } }
    }
}

func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
/// Always opens in the plain-text editor, so a symlinked or misnamed file can't launch an app or script.
func openFile(_ url: URL) {
    guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { return }
    NSWorkspace.shared.open([url.resolvingSymlinksInPath()], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
}

func relative(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(.relative(presentation: .named))
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
