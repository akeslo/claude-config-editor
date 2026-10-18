import ConfigCore
import SwiftUI

/// Skills from community lists; Install… downloads the repo and proposes a copy (or a marketplace add).
struct CommunityView: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var hideInstalled = true
    @State private var selection: CommunitySkill.ID?
    @State private var busy: String?
    @State private var error: String?
    @State private var choices: [FoundSkill] = []
    @State private var picked: Set<String> = []
    @State private var choicesLink: URL?

    var body: some View {
        let installedSkills = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.claudeDir.appending(path: "skills").path)) ?? [])
        let knownRepos = Set((readJSON(Paths.claudeDir.appending(path: "plugins/known_marketplaces.json")) ?? [:]).values
            .compactMap { (($0 as? JSON)?["source"] as? JSON)?["repo"] as? String }.map { $0.lowercased() })
        let installed = { (s: CommunitySkill) in s.marketplace ? knownRepos.contains(s.slug.lowercased()) : installedSkills.contains(s.name) }
        let list = model.community
            .filter { !hideInstalled || !installed($0) }
            .filter { search.isEmpty || [$0.name, $0.description, $0.category].contains { $0.localizedCaseInsensitiveContains(search) } }
        let titles = Dictionary(uniqueKeysWithValues: CommunityList.allCases.map { ($0.rawValue, $0.title) })
        VStack(spacing: 0) {
            if let busy { ProgressView(busy).controlSize(.small).padding(6) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(6).textSelection(.enabled) }
            if model.community.isEmpty {
                ProgressView("Loading community lists…").frame(maxHeight: .infinity)
            } else {
                Table(list, selection: $selection) {
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
                    TableColumn("") { s in Text(installed(s) ? "Installed" : "").foregroundStyle(.secondary) }.width(70)
                }
            }
        }
        .toolbar {
            Toggle("Hide installed", isOn: $hideInstalled)
            if let s = list.first(where: { $0.id == selection }), !installed(s), busy == nil {
                Button("Install…") { Task { await install(s) } }
                    .help("Only install skills you trust: scripts in a skill can run on your machine.")
            }
        }
        .task { await model.loadCommunity() }
        .onChange(of: selection) {
            guard let s = list.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(s.name, term: .skill, facts: [("Repo", s.slug), ("Category", s.category), ("List", titles[s.list] ?? s.list)]
                                  + (s.stars.map { [("Stars", $0.formatted())] } ?? []), link: s.link, text: s.description)
        }
        .sheet(isPresented: .init(get: { !choices.isEmpty }, set: { if !$0 { choices = [] } })) { chooser }
    }

    private func proposeMarketplace(_ slug: String) {
        model.propose("Add marketplace \(slug)", .cli(args: ["plugin", "marketplace", "add", slug], dryRun: nil, cwd: nil))
    }

    private func install(_ s: CommunitySkill) async {
        error = nil
        if s.marketplace { proposeMarketplace(s.slug); return }
        model.clearCommunityDownloads()
        busy = "Downloading \(s.slug)…"
        defer { busy = nil }
        let root: URL
        do { root = try await downloadRepo(s.slug) } catch { self.error = error.localizedDescription; return }
        model.communityDownloads.append(root)
        if hasMarketplace(root) { model.clearCommunityDownloads(); proposeMarketplace(s.slug); return }
        let base = s.path.map { root.appending(path: $0) } ?? root
        let rootPath = root.standardizedFileURL.path
        guard base.standardizedFileURL.path == rootPath || base.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
            model.clearCommunityDownloads(); error = "Refusing \(s.slug): its path leaves the repo."; return
        }
        let found = findSkills(in: base, fallbackName: s.path == nil ? String(s.slug.split(separator: "/").last ?? "") : base.lastPathComponent)
        let link = URL(string: "https://github.com/\(s.slug)")
        switch found.count {
        case 0: model.clearCommunityDownloads(); error = "No SKILL.md found in \(s.slug)" + (s.path.map { "/\($0)" } ?? "") + "."
        case 1: model.propose("Install skill \(found[0].name)", .installSkills([SkillCopy(from: found[0].dir, name: found[0].name, link: link)]))
        default: choicesLink = link; picked = Set(found.map(\.name)); choices = found
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose skills to install").font(.title3.weight(.semibold))
            List(choices, id: \.self) { f in
                Toggle(isOn: .init(get: { picked.contains(f.name) }, set: { if $0 { picked.insert(f.name) } else { picked.remove(f.name) } })) {
                    Text(f.name) + Text("  \(f.files.count) file(s)" + (f.scripts.isEmpty ? "" : ", ⚠ runs code")).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { choices = []; model.clearCommunityDownloads() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let copies = choices.filter { picked.contains($0.name) }.map { SkillCopy(from: $0.dir, name: $0.name, link: choicesLink) }
                    choices = []
                    model.propose("Install \(copies.count) skill(s)", .installSkills(copies))
                }
                .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}
