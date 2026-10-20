import SwiftUI
import ConfigCore

/// Ask: one question about the open screen, one answer, in a sheet (⌘K). The ask itself is sandboxed (ClaudeCLI.askResult).
struct AskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var close
    let section: AppSection
    @State private var question = ""
    @State private var answer: String?
    @State private var failReason: String?
    @State private var asking = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s3) {
            HStack {
                TextField("Ask about \(model.screen.title)…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Ask", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Gap.s2) {
                    if asking {
                        LoadingState(title: "Asking Claude…").frame(height: 200)
                    } else if let failReason {
                        Text("Claude didn't answer: \(failReason)").foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let answer {
                        ForEach(Array(AnswerBlocks.segments(answer).enumerated()), id: \.offset) { _, seg in
                            switch seg {
                            case .text(let t):
                                Text(AnswerBlocks.rich(t)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .code(_, let body):
                                VStack(alignment: .trailing, spacing: 2) {
                                    Button("Copy") { copy(body) }.controlSize(.small).help("Copy just this block, without the ``` fences")
                                    Text(body).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    } else {
                        Text("Sends this screen's rows (secrets masked) to a sandboxed claude -p. AI answer, not verified.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                if let answer { Button("Copy Answer") { copy(answer) } }
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Gap.s4)
        .frame(width: 640, height: 460)
        .onDisappear { task?.cancel() }
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true; answer = nil; failReason = nil
        task = Task {
            let r = await model.askWithScreen(q, about: section)
            guard !Task.isCancelled else { return }
            asking = false
            switch r {
            case .success(let a): answer = a
            case .failure(let f): failReason = f.reason
            }
        }
    }
}

extension AppModel {
    var screenProvider: (any Provider)? { detected.first { $0.0.id == screen.provider }?.0 }
    var isClaudeScreen: Bool { (screen.provider ?? .claude) == .claude }
    /// Existing files for the open provider screen (folders one level down), credentials never included.
    func providerFiles(_ p: any Provider) -> [URL] {
        guard case .kind(_, let k) = screen else { return [] }
        return Screen.kinds(shownOn: k).flatMap { p.paths(for: $0, home: Paths.home, project: nil) }.flatMap { u in
            u.hasDirectoryPath || (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                : [u]
        }.filter { exists($0) && !$0.hasDirectoryPath }
    }

    /// Sends the full screen snapshot (ScreenContext) plus copies of the listed config files (never ~/.claude itself, never credentials).
    func askWithScreen(_ question: String, about section: AppSection) async -> Result<String, AskFailure> {
        // The open screen's provider asks when it can; else Claude Code (only Claude has a sandboxed ask today, so that is ClaudeCLI below).
        guard ProviderRegistry.askCommand(for: self.screen.provider, home: Paths.home, env: ProcessInfo.processInfo.environment) != nil else {
            return .failure(AskFailure(reason: "No provider on this machine can answer: install Claude Code."))
        }
        if !isClaudeScreen, let p = screenProvider {
            let files = providerFiles(p)
            let prompt = askPrompt(question: question, screen: screenInfo(section, question: question), section: section, cap: ScreenContext.defaultBudget + 10_000)
                + "\nCopies of the listed \(p.displayName) config files are in the current directory (by file name); read them with Read, Grep and Glob. Do not modify anything."
                + " Answer in plain short paragraphs or bullets, citing file names."
            return await ClaudeCLI.askResult(prompt, model: "sonnet", tools: ["Read", "Grep", "Glob"], files: files)
        }
        let screen = screenInfo(section, question: question)
        // Skills: the list above is complete, so no file tools; other screens get copies of the shown files in the ask cwd.
        let readFiles = section != .skills
        let prompt = askPrompt(question: question, screen: screen, section: section, cap: ScreenContext.defaultBudget + 10_000)
            + (readFiles ? "\nCopies of the user settings, CLAUDE.md and the listed component files are in the current directory (by file name); read them with Read, Grep and Glob for detail. Do not modify anything."
                         : "\nAnswer only from the list above; it is complete. Do not offer to search, read files or run anything.")
            + " Answer in plain short paragraphs or bullets, citing item names."
        let files = readFiles ? [Paths.userSettings, Paths.userClaudeMD] + snapshot.components.map(\.file) : []
        return await ClaudeCLI.askResult(prompt, model: "sonnet", tools: readFiles ? ["Read", "Grep", "Glob"] : [], files: files)
    }

    /// What the screen shows, as text (secrets masked): rows with source/scope labels, usage, warnings. Shared by Ask Claude and Copy info.
    func screenInfo(_ section: AppSection, question: String = "") -> String {
        if !isClaudeScreen, let p = screenProvider {
            return "\(p.displayName) · \(screen.title)\n\nFiles:\n" + providerFiles(p).map { "- " + $0.path }.joined(separator: "\n")
        }
        let screen = ScreenContext.build(section, snapshot, issues: issues, question: question)
        return screen
    }

}
