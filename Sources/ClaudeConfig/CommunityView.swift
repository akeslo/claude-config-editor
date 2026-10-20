import ConfigCore
import SwiftUI

/// Skills from community lists; Install… downloads the repo and proposes a copy (or a marketplace add).
struct CommunityView: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var hideInstalled = true
    @State private var sel = BulkSelection<String>()
    @State private var picked: Set<String> = []

    var body: some View {
        let installed = model.communityInstalled()
        let list = model.community
            .filter { !hideInstalled || !installed($0) }
            .filter { search.isEmpty || [$0.name, $0.description, $0.category].contains { $0.localizedCaseInsensitiveContains(search) } }
        let titles = Dictionary(uniqueKeysWithValues: CommunityList.allCases.map { ($0.rawValue, $0.title) })
        VStack(spacing: 0) {
            if let busy = model.communityBusy { ProgressView(busy).controlSize(.small).padding(6) }
            if let error = model.communityError { Text(error).foregroundStyle(PColor.danger.fg).font(.callout).padding(6).textSelection(.enabled) }
            if model.community.isEmpty {
                switch model.communityStatus {
                case .connecting, .connected: ProgressView("Fetching community skill lists…").frame(maxHeight: .infinity)
                case .notSetUp:
                    ContentUnavailableView {
                        Label("No community lists yet", systemImage: "books.vertical")
                    } description: {
                        Text("Community skill lists download from GitHub the first time you open this tab. Fetch them now to browse skills other people share.")
                    } actions: { Button("Fetch lists") { Task { await model.loadCommunity(force: true) } } }
                case .disconnected:
                    ContentUnavailableView {
                        Label("Can't reach the community lists", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("These lists loaded before but GitHub didn't answer this time. Check your connection, then try again.")
                    } actions: { Button("Try again") { Task { await model.loadCommunity(force: true) } } }
                }
            } else {
                Table(list, selection: $sel.ids) {
                    TableColumn("") { (s: CommunitySkill) in SelectBox(sel: $sel, id: s.id, visible: list.map(\.id), name: s.name) }.width(22)
                    TableColumn("Skill") { s in
                        VStack(alignment: .leading) {
                            Text(s.name).fontWeight(.medium)
                            Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .explains(.skill, s.description)
                    }
                    TableColumn("Category") { Text($0.category) }.width(150)
                    TableColumn("List") { Text(titles[$0.list] ?? $0.list) }.width(150)
                    TableColumn("Stars") { Text($0.stars?.formatted() ?? "").monospacedDigit() }.width(60)
                    TableColumn("") { s in
                        if installed(s) { Text("Installed").foregroundStyle(.secondary) }
                        else { Button("Install…") { model.startCommunityInstall(s) }.disabled(model.communityBusy != nil)
                            .help("Only install skills you trust: scripts in a skill can run on your machine.") }
                    }.width(90)
                }
                .bulkSelectable($sel, visible: list.map(\.id), actions: [
                    BulkAction(title: "Install selected…", icon: "arrow.down.circle",
                               check: model.communityBusy != nil ? BulkCheck(enabled: false, why: "An install is already in progress") : bulkCheck(model.community.filter { sel.contains($0.id) }) { _ in nil }) {
                        model.installCommunity(model.community.filter { sel.contains($0.id) })
                    },
                ])
            }
        }
        .toolbar {
            Toggle("Hide installed", isOn: $hideInstalled)
        }
        .task { await model.loadCommunity() }
        .onChange(of: sel.ids) {
            guard sel.count == 1, let s = list.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem(s.name, term: .skill, facts: [("Repo", s.slug), ("Category", s.category), ("List", titles[s.list] ?? s.list)]
                                  + (s.stars.map { [("Stars", $0.formatted())] } ?? []), link: s.link, text: s.description)
        }
        .onChange(of: model.communityChoices) { picked = Set(model.communityChoices.map(\.name)) }
        .sheet(isPresented: .init(get: { !model.communityChoices.isEmpty }, set: { if !$0 { model.communityChoices = [] } })) { chooser }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose skills to install").font(.title3.weight(.semibold))
            List(model.communityChoices, id: \.self) { f in
                Toggle(isOn: .init(get: { picked.contains(f.name) }, set: { if $0 { picked.insert(f.name) } else { picked.remove(f.name) } })) {
                    Text(f.name) + Text("  \(f.files.count) file(s)" + (f.scripts.isEmpty ? "" : ", ⚠ runs code")).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.communityChoices = []; model.clearCommunityDownloads() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let copies = model.communityChoices.filter { picked.contains($0.name) }.map { SkillCopy(from: $0.dir, name: $0.name, link: model.communityChoicesLink) }
                    model.communityChoices = []
                    model.propose("Install \(copies.count) skill(s)", .installSkills(copies))
                }
                .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

extension AppModel {
    func proposeMarketplace(_ slug: String) {
        propose("Add marketplace \(slug)", .cli(args: ["plugin", "marketplace", "add", slug], dryRun: nil, cwd: nil))
    }

    func startCommunityInstall(_ s: CommunitySkill) {
        guard communityBusy == nil else { return }
        communityError = nil
        if s.marketplace { proposeMarketplace(s.slug); return }
        clearCommunityDownloads()
        communityBusy = "Downloading \(s.slug)…"
        Task { await installCommunity(s); communityBusy = nil }
    }

    /// Bulk install: downloads every selected repo, then one Install to sheet for every skill found.
    /// Marketplaces, failed downloads and repos without a SKILL.md are reported as skipped.
    func installCommunity(_ list: [CommunitySkill]) {
        guard communityBusy == nil, !list.isEmpty else { return }
        if list.count == 1 { startCommunityInstall(list[0]); return }
        communityError = nil
        clearCommunityDownloads()
        let installed = communityInstalled()
        Task {
            var copies: [SkillCopy] = [], skipped: [String] = []
            for (i, s) in list.enumerated() {
                if installed(s) { skipped.append("\(s.name): already installed"); continue }
                if s.marketplace { skipped.append("\(s.name): a marketplace, add it on its own"); continue }
                communityBusy = "Downloading \(i + 1) of \(list.count): \(s.slug)…"
                guard let root = try? await downloadRepo(s.slug) else { skipped.append("\(s.name): download failed"); continue }
                communityDownloads.append(root)
                guard let base = skillBase(root: root, path: s.path) else { skipped.append("\(s.name): path missing or leaves the repo"); continue }
                let found = findSkills(in: base, fallbackName: s.path == nil ? String(s.slug.split(separator: "/").last ?? "") : base.lastPathComponent)
                if found.isEmpty { skipped.append("\(s.name): no SKILL.md") }
                copies += found.map { SkillCopy(from: $0.dir, name: $0.name, link: URL(string: "https://github.com/\(s.slug)")) }
            }
            communityBusy = nil
            if !skipped.isEmpty { communityError = "Skipped \(skipped.count): " + skipped.joined(separator: "; ") }
            if copies.isEmpty { clearCommunityDownloads() } else { propose("Install \(copies.count) skill(s)", .installSkills(copies)) }
        }
    }

    private func installCommunity(_ s: CommunitySkill) async {
        let root: URL
        do { root = try await downloadRepo(s.slug) } catch { communityError = error.localizedDescription; return }
        communityDownloads.append(root)
        // A row naming one skill folder installs that skill even when the repo is also a marketplace.
        if s.path == nil, hasMarketplace(root) { clearCommunityDownloads(); proposeMarketplace(s.slug); return }
        guard let base = skillBase(root: root, path: s.path) else {
            clearCommunityDownloads(); communityError = "Refusing \(s.slug): its path is missing or leaves the repo."; return
        }
        let found = findSkills(in: base, fallbackName: s.path == nil ? String(s.slug.split(separator: "/").last ?? "") : base.lastPathComponent)
        let link = URL(string: "https://github.com/\(s.slug)")
        switch found.count {
        case 0: clearCommunityDownloads(); communityError = "No SKILL.md found in \(s.slug)" + (s.path.map { "/\($0)" } ?? "") + "."
        case 1: propose("Install skill \(found[0].name)", .installSkills([SkillCopy(from: found[0].dir, name: found[0].name, link: link)]))
        default: communityChoicesLink = link; communityChoices = found
        }
    }
}
