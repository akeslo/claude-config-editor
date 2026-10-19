import ConfigCore
import SwiftUI

/// ⌘, window. Only app preferences live here; Claude Code's own settings are on the Settings page.
struct AppSettingsView: View {
    @Binding var showMenuBar: Bool
    @AppStorage("analyzeOnLaunch") private var analyzeOnLaunch = true
    @AppStorage("installUserOnly") private var installUserOnly = true
    @AppStorage("askAutoCopyPrompt") private var askAutoCopy = true

    var body: some View {
        Form {
            Toggle("Ask Claude to review my skills when the app opens", isOn: $analyzeOnLaunch)
            Text("Sends skill names, short descriptions and usage counts to Claude (haiku) at most once a day, or when your skills change.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Copy prompts from Ask Claude automatically", isOn: $askAutoCopy)
            Text("When you ask for a prompt and the answer holds one code block, it goes straight to the clipboard (with Undo).")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Show skills in the menu bar", isOn: $showMenuBar)
            Text("A searchable list of every skill you can call, for when you can't remember the right /name.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Install skills as \"Only when I call it\"", isOn: $installUserOnly)
            Text("New skill installs get disable-model-invocation: true, so they run only as /name. The install sheet can override this per install.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: showMenuBar) { UserDefaults.standard.set(showMenuBar, forKey: "showSkillsMenuBar") }
        .frame(width: 420)
        .fixedSize()
    }
}

/// Menu bar cheat sheet: every callable skill, searchable, with an AI pick for a described use case. Click copies /name.
struct MenuBarSkills: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var useCase = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var expanded: String?
    @State private var copied: String?
    @State private var picked = BulkSelection<String>()

    /// Personal, project and enabled-plugin skills that aren't Off.
    private var skills: [Component] {
        let enabled = Set(model.snapshot.plugins.filter(\.enabled).map(\.id))
        return model.snapshot.components
            .filter { $0.kind == .skill && $0.state != .off && ($0.ownsFile || $0.scope == .external || $0.owner.map(enabled.contains) == true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let all = skills
        let catalog = Recommendations.search(search, available: model.available, community: model.community)
        let shown = all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: Space.s) {
            TextField("Search \(all.count) skills, plugins and community", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Ask AI: what do you want to do?", text: $useCase).textFieldStyle(.roundedBorder).onSubmit(ask)
                if asking { ProgressView().controlSize(.small) } else {
                    Button("Ask", action: ask).disabled(useCase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let answer {
                Text(answer).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .help("An unverified AI suggestion from claude -p (haiku)")
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { row($0, shown.map(\.id)) }
                    if !catalog.isEmpty {
                        Text("Available to install").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, Space.s)
                        ForEach(catalog) { RecommendationRow(item: $0) }
                    }
                }
            }
            .frame(height: 360)
            .bulkKeys($picked, visible: shown.map(\.id))
            .overlay { if shown.isEmpty && catalog.isEmpty { Text(!all.isEmpty ? "No matches" : model.loading ? "Loading skills…" : "No skills yet. Open Claude Config to set up your first one.").foregroundStyle(.secondary) } }
            HStack {
                SelectAllBox(sel: $picked, visible: shown.map(\.id))
                if !picked.isEmpty { Text(picked.label(shown.map(\.id))).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                CopyPromptButton(skills: all.filter { picked.contains($0.id) }, picked: $picked)
            }
            if let copied { Label("Copied \(copied)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
        }
        .padding(Space.m)
        .frame(width: 380)
        .task {
            if model.snapshot.components.isEmpty { await model.refresh() }
            // Loaded once per popover open, never per keystroke.
            if model.available.isEmpty { model.available = await Scanner.available() }
            await model.loadCommunity()
        }
    }

    private func row(_ s: Component, _ visibleIDs: [String]) -> some View {
        let open = expanded == s.id
        return HStack(alignment: .top, spacing: Space.s) {
            SelectBox(sel: $picked, id: s.id, visible: visibleIDs, name: "/" + s.name)
            Button { copy("/" + s.name); flash("/" + s.name) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("/" + s.name).font(.body.monospaced())
                        Spacer()
                        Text("\(s.scope == .external ? s.belongsTo : s.owner.map { "plugin \($0)" } ?? s.scope.rawValue + " · " + s.agents.map(\.rawValue).joined(separator: ", ")) · " + (s.state == .always ? "Always" : s.state.rawValue)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(open ? s.description : purpose(s)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(open ? nil : 1).fixedSize(horizontal: false, vertical: open)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy /\(s.name)")
            Button(open ? "Less" : "More", systemImage: open ? "chevron.up" : "chevron.down") { expanded = open ? nil : s.id }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(open ? "Show less" : "Show the full description")
        }
        .padding(.vertical, Space.xs)
    }

    private func ask() {
        let q = useCase.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        asking = true
        Task {
            answer = await model.matchSkills(q, among: skills)
            asking = false
        }
    }

    private func flash(_ name: String) {
        copied = name
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == name { copied = nil }
        }
    }
}
