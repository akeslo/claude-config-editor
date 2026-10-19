import SwiftUI
import ConfigCore

/// One question about the current screen, one answer; a new question replaces it. Cleared by `.id(section)` at the call site.
struct AskClaudeBar: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    @State private var question = ""
    @State private var answer: String?
    @State private var picks: [Recommendations.Item] = []
    @State private var sel = BulkSelection<String>()
    @State private var failed = false
    @State private var asking = false
    @State private var task: Task<Void, Never>?
    @State private var copied: String?
    @State private var autoCopied: (previous: String?, copied: String)?
    @AppStorage("askAutoCopyPrompt") private var autoCopy = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Ask Claude about this screen…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if asking { ProgressView().controlSize(.small) }
                Button("Ask", action: submit)
                    .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if failed {
                Text("Claude didn't answer. Is the `claude` command installed?").font(.caption).foregroundStyle(.secondary)
            } else if let answer {
                // Scrolls past a cap: unbounded, the answer squeezed against the greedy detail view below and was truncated.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(AnswerBlocks.segments(answer).enumerated()), id: \.offset) { _, seg in
                            switch seg {
                            case .text(let t):
                                Text(t).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .code(_, let body):
                                codeBlock(body)
                            }
                        }
                        if !picks.isEmpty {
                            let visible = picks.map(\.id)
                            BulkBar(sel: $sel, visible: visible, actions: model.installActions(picks.filter { sel.contains($0.id) })).padding(.horizontal, -Space.l)
                            VStack(alignment: .leading, spacing: 0) { ForEach(picks) { RecommendationRow(item: $0, sel: $sel, visible: visible) } }
                                .padding(.vertical, 4)
                                .bulkKeys($sel, visible: visible)
                        }
                    }
                }
                .frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("AI suggestion — not verified").font(.caption).foregroundStyle(.secondary)
                    if let a = autoCopied {
                        Label("Prompt copied to clipboard", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                        Button("Undo") { if let p = a.previous { setClipboard(p) } else { NSPasteboard.general.clearContents() }; autoCopied = nil }.buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                    Button(copied == answer ? "Copied" : "Copy answer") { copyNow(answer) }.controlSize(.small)
                        .help("Copy the whole answer as text")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onDisappear { task?.cancel() }
        // Launch with `-autoAsk "question"` to ask once on start (headless verification).
        .task(id: model.loading) { if !model.loading, !model.snapshot.components.isEmpty, let q = UserDefaults.standard.string(forKey: "autoAsk"), answer == nil, !asking { question = q; submit() } }
    }

    private func codeBlock(_ body: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(copied == body ? "Copied" : "Copy") { copyNow(body) }.controlSize(.small).help("Copy just this block, without the ``` fences")
            Text(body).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copyNow(_ text: String) { setClipboard(text); copied = text; autoCopied = nil }
    private func setClipboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true; answer = nil; picks = []; failed = false; autoCopied = nil; copied = nil
        task = Task {
            let a = await model.askWithScreen(q, about: section)
            guard !Task.isCancelled else { return }
            asking = false
            failed = a == nil
            if let a, section == .discover {
                let parsed = Recommendations.parse(a)
                answer = parsed.prose
                picks = Recommendations.match(parsed.picks, available: model.available, community: model.community)
            } else { answer = a }
            if autoCopy, let a, let text = AnswerBlocks.autoCopyText(question: q, answer: a) {
                autoCopied = (NSPasteboard.general.string(forType: .string), text)
                setClipboard(text)
            }
            if UserDefaults.standard.string(forKey: "autoAsk") != nil { print("ASK-ANSWER:\n" + (a ?? "<none>")); fflush(stdout) }
        }
    }
}

extension AppModel {
    /// Sends the full screen snapshot (ScreenContext) and lets Claude read ~/.claude with read-only tools.
    func askWithScreen(_ question: String, about section: AppSection) async -> String? {
        let screen = screenInfo(section, question: question)
        let prompt = askPrompt(question: question, screen: screen, section: section, cap: ScreenContext.defaultBudget + 10_000)
            + "\nYou may read files under \(Paths.claudeDir.path) (and paths listed above) with Read, Grep and Glob for detail. Do not modify anything. Answer in plain short paragraphs or bullets, citing item names."
            + (section == .discover ? "\n" + Recommendations.instruction : "")
        return await runAsk(prompt)
    }

    /// What the screen shows, as text (secrets masked): rows with source/scope labels, usage, warnings. Shared by Ask Claude and Copy info.
    func screenInfo(_ section: AppSection, question: String = "") -> String {
        let discover = section == .discover ? ScreenContext.Discover(
            tab: UserDefaults.standard.string(forKey: "discoverTab") ?? "community", search: discoverSearch,
            available: available, community: community, communityInstalled: Set(community.filter(communityInstalled()).map(\.id))) : nil
        let screen = ScreenContext.build(section, snapshot, issues: issues, advice: advice, storage: storage,
                                         discover: discover, analytics: analytics, skillMap: section == .mySkills ? skillMapContext : nil, question: question)
        return screen
    }

    private func runAsk(_ prompt: String) async -> String? {
        guard let exe = ClaudeCLI.executable else { return nil }
        let args = ["-p", prompt, "--model", "sonnet", "--settings", #"{"disableAllHooks":true}"#, "--no-session-persistence",
                    "--add-dir", Paths.claudeDir.path, "--tools", "Read,Grep,Glob", "--allowedTools", "Read", "Grep", "Glob",
                    "--disallowedTools", "Write", "Edit", "Bash", "NotebookEdit", "WebFetch"]
        return await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = Paths.claudeDir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(exe.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["NO_COLOR"] = "1"
            // Lets a fixture-HOME test run reach a signed-in CLI while the app reads fixture data.
            if let h = env["CLAUDE_CONFIG_EDITOR_CLI_HOME"] { env["HOME"] = h }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && !text.isEmpty ? text : nil
        }.value
    }
}

extension AppModel {
    /// Whether a community skill looks installed. The folder name an install would use isn't known before download
    /// (SKILL.md `name:`), so match likely ones.
    func communityInstalled() -> (CommunitySkill) -> Bool {
        let installedSkills = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.claudeDir.appending(path: "skills").path)) ?? [])
        let knownRepos = Set((readJSON(Paths.claudeDir.appending(path: "plugins/known_marketplaces.json")) ?? [:]).values
            .compactMap { (($0 as? JSON)?["source"] as? JSON)?["repo"] as? String }.map { $0.lowercased() })
        return { s in
            if s.marketplace { return knownRepos.contains(s.slug.lowercased()) }
            let folder: Substring = (s.path ?? s.slug).split(separator: "/").last ?? ""
            return installedSkills.contains(s.name) || installedSkills.contains(String(folder))
        }
    }
}

extension AppModel {
    /// The one plugin install path (Discover table, Ask recommendations, menu bar search).
    func installPlugin(_ p: AvailablePlugin) { propose("Install \(p.id)", .cli(args: ["plugin", "install", p.id], dryRun: nil, cwd: nil)) }
    func isInstalled(_ p: AvailablePlugin) -> Bool { p.installed || snapshot.plugins.contains { $0.id == p.id } }

    func proposePluginInstalls(_ ps: [AvailablePlugin]) {
        proposeBulk("Install \(ps.count) plugin\(ps.count == 1 ? "" : "s")", bulkPlan(ps, label: \.id, skip: { self.isInstalled($0) ? "already installed" : nil }) {
            .cli(args: ["plugin", "install", $0.id], dryRun: nil, cwd: nil)
        })
    }

    /// "Install selected" for recommendation rows: plugins in one confirm sheet, community skills through one Install to sheet.
    func installActions(_ items: [Recommendations.Item]) -> [BulkAction] {
        let plugins = items.compactMap { if case .plugin(let p, _) = $0 { p } else { nil } }
        let skills = items.compactMap { if case .community(let s, _) = $0 { s } else { nil } }
        let check = !plugins.isEmpty && !skills.isEmpty
            ? BulkCheck(enabled: false, why: "\(plugins.count) of \(items.count) are plugins and \(skills.count) are community skills; install each kind separately")
            : bulkCheck(items) { _ in nil }
        return [BulkAction(title: "Install selected…", icon: "arrow.down.circle", check: check) {
            if plugins.isEmpty { self.installCommunity(skills) } else { self.proposePluginInstalls(plugins) }
        }]
    }
}

extension Recommendations.Item {
    var name: String { switch self { case .plugin(let p, _): p.name; case .community(let s, _): s.name } }
}

/// One installable catalog item: name, source, a one-line reason and the same Install action as Discover's tables.
struct RecommendationRow: View {
    @Environment(AppModel.self) private var model
    let item: Recommendations.Item
    var sel: Binding<BulkSelection<String>>?
    var visible: [String] = []

    var body: some View {
        let installed = model.communityInstalled()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sel { SelectBox(sel: sel, id: item.id, visible: visible, name: item.name) }
            VStack(alignment: .leading, spacing: 1) {
                switch item {
                case .plugin(let p, let reason):
                    (Text(p.name).fontWeight(.medium) + Text("  " + p.marketplace).foregroundStyle(.secondary).font(.caption))
                    if !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                case .community(let s, let reason):
                    (Text(s.name).fontWeight(.medium) + Text("  " + s.slug).foregroundStyle(.secondary).font(.caption))
                    if !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            switch item {
            case .plugin(let p, _):
                if model.isInstalled(p) { Text("Installed").foregroundStyle(.secondary) }
                else { Button("Install…") { model.installPlugin(p) }.help("Runs claude plugin install. Only install plugins you trust: they can run code on your machine.") }
            case .community(let s, _):
                if installed(s) { Text("Installed").foregroundStyle(.secondary) }
                else if model.communityBusy != nil { ProgressView().controlSize(.small).help(model.communityBusy ?? "") }
                else { Button("Install…") { model.startCommunityInstall(s) }.help("Only install skills you trust: scripts in a skill can run on your machine.") }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 3)
        .overlay(alignment: .bottomLeading) {
            if case .community = item, let e = model.communityError { Text(e).font(.caption2).foregroundStyle(.red).offset(y: 10).lineLimit(1) }
        }
    }
}
