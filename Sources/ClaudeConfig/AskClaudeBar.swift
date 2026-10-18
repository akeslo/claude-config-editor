import SwiftUI
import ConfigCore

/// One question about the current screen, one answer; a new question replaces it. Cleared by `.id(section)` at the call site.
struct AskClaudeBar: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    @State private var question = ""
    @State private var answer: String?
    @State private var failed = false
    @State private var asking = false
    @State private var task: Task<Void, Never>?

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
                Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("AI suggestion — not verified").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onDisappear { task?.cancel() }
        // Launch with `-autoAsk "question"` to ask once on start (headless verification).
        .task(id: model.loading) { if !model.loading, !model.snapshot.components.isEmpty, let q = UserDefaults.standard.string(forKey: "autoAsk"), answer == nil, !asking { question = q; submit() } }
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true; answer = nil; failed = false
        task = Task {
            let a = await model.askWithScreen(q, about: section)
            guard !Task.isCancelled else { return }
            asking = false
            answer = a; failed = a == nil
            if UserDefaults.standard.string(forKey: "autoAsk") != nil { print("ASK-ANSWER:\n" + (a ?? "<none>")); fflush(stdout) }
        }
    }
}

extension AppModel {
    /// Sends the full screen snapshot (ScreenContext) and lets Claude read ~/.claude with read-only tools.
    func askWithScreen(_ question: String, about section: AppSection) async -> String? {
        let discover = section == .discover ? ScreenContext.Discover(
            tab: UserDefaults.standard.string(forKey: "discoverTab") ?? "plugins", search: discoverSearch,
            available: available, community: community, communityInstalled: Set(community.filter(communityInstalled()).map(\.id))) : nil
        let screen = ScreenContext.build(section, snapshot, issues: issues, advice: advice, storage: storage,
                                         discover: discover, analytics: analytics, question: question)
        let prompt = askPrompt(question: question, screen: screen, section: section, cap: ScreenContext.defaultBudget + 10_000)
            + "\nYou may read files under \(Paths.claudeDir.path) (and paths listed above) with Read, Grep and Glob for detail. Do not modify anything. Answer in plain short paragraphs or bullets, citing item names."
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
