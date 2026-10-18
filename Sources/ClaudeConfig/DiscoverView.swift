import ConfigCore
import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var hideInstalled = true
    @State private var sel = BulkSelection<String>()
    @State private var loadError: String?
    @State private var loading = false
    @State private var sort = [KeyPathComparator(\AvailablePlugin.installCount, order: .reverse)]
    // Also settable at launch with `-discoverTab community` (screenshots).
    @AppStorage("discoverTab") private var tab = "community"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Community skills").tag("community")
                Text("Plugins").tag("plugins")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(8)
            DiscoverReviewPanel()
            if tab == "community" { CommunityView(search: search) } else { plugins }
        }
        .searchable(text: $search, prompt: "Search plugins and skills")
        .onChange(of: search) { model.discoverSearch = search }
        .onAppear { search = model.discoverSearch }
    }

    @ViewBuilder private var plugins: some View {
        let list = model.available
            .filter { !hideInstalled || !$0.installed }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Group {
            if loadError != nil, model.available.isEmpty, !CatalogStatus.marketplacesSetUp() {
                ContentUnavailableView {
                    Label("No plugin marketplaces yet", systemImage: "shippingbox")
                } description: {
                    Text("Plugins come from marketplaces. Add one with `claude plugin marketplace add <owner/repo>`, or browse Community skills in the meantime.")
                } actions: {
                    Button("Browse community skills") { tab = "community" }
                    Button("Check again") { Task { await load() } }
                }
            } else if let loadError, model.available.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't list plugins", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError).textSelection(.enabled) } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if model.available.isEmpty {
                ProgressView("Asking claude for marketplace plugins… (runs `claude plugin list --available`, a few seconds)")
            } else {
                Table(list, selection: $sel.ids, sortOrder: $sort) {
                    TableColumn("", value: \AvailablePlugin.name) { (p: AvailablePlugin) in SelectBox(sel: $sel, id: p.id, visible: list.map(\.id), name: p.name) }.width(22)
                    TableColumn("Plugin", value: \AvailablePlugin.name) { (p: AvailablePlugin) in
                        VStack(alignment: .leading) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .explains(.plugin, p.description)
                    }
                    TableColumn("Marketplace", value: \AvailablePlugin.marketplace) { (p: AvailablePlugin) in Text(p.marketplace).help(Term.marketplace.tooltip) }.width(170)
                    TableColumn("Installs", value: \AvailablePlugin.installCount) { (p: AvailablePlugin) in Text(p.installCount.formatted()).monospacedDigit() }.width(80)
                    TableColumn("", value: \AvailablePlugin.name) { (p: AvailablePlugin) in
                        if p.installed { Text("Installed").foregroundStyle(.secondary) }
                        else { Button("Install…") { install(p) }.help("Runs claude plugin install. Only install plugins you trust: they can run code on your machine.") }
                    }.width(90)
                }
                .bulkSelectable($sel, visible: list.map(\.id), actions: [
                    BulkAction(title: "Install selected…", icon: "arrow.down.circle", check: bulkCheck(model.available.filter { sel.contains($0.id) }) { _ in nil }) {
                        model.proposePluginInstalls(model.available.filter { sel.contains($0.id) })
                    },
                ])
            }
        }
        .toolbar {
            Toggle("Hide installed", isOn: $hideInstalled)
        }
        .task { if model.available.isEmpty { await load() } }
        .onChange(of: sel.ids) {
            guard sel.count == 1, let p = list.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem(p.name, term: .marketplace, facts: [("ID", p.id), ("Marketplace", p.marketplace), ("Installs", p.installCount.formatted())], link: p.repoURL, text: p.description)
        }
    }

    private func install(_ p: AvailablePlugin) { model.installPlugin(p) }

    /// A failed or empty CLI call used to leave the spinner up forever, which read as "nothing happened".
    private func load() async {
        guard !loading else { return }
        loading = true; loadError = nil
        defer { loading = false }
        model.available = await Scanner.available()
        if model.available.isEmpty {
            let r = await ClaudeCLI.run(["plugin", "list", "--json", "--available"])
            loadError = r.ok ? "claude returned no marketplace plugins. Add a marketplace with `claude plugin marketplace add <repo>`."
                : "claude plugin list failed (exit \(r.status)): \(r.output.prefix(400))"
        }
    }
}
