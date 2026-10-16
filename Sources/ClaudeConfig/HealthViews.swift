import ConfigCore
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Issue.ID?
    @State private var checked: Set<Issue.ID> = []

    var body: some View {
        let issues = model.issues
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                Metric(value: formatTokens(model.startupTokens), label: "startup context (user-wide)", term: .contextWindow)
                Metric(value: model.storage.isEmpty ? "…" : formatBytes(model.diskBytes), label: "used on disk", term: .scratch)
                Metric(value: "\(issues.filter { $0.severity == .problem }.count)", label: "problems", term: .contextWindow)
                Metric(value: "\(issues.filter { $0.severity == .warning }.count)", label: "warnings", term: .contextWindow)
                Spacer()
                if let v = model.snapshot.claudeVersion { Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding()
            Divider()
            if !issues.isEmpty {
                let picked = issues.filter { checked.contains($0.id) }
                HStack {
                    Button(checked.count == issues.count ? "Uncheck All" : "Check All") {
                        checked = checked.count == issues.count ? [] : Set(issues.map(\.id))
                    }
                    Text(picked.isEmpty ? "Check issues to fix them together" : "\(picked.count) checked").foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Prompt for Checked", systemImage: "doc.on.clipboard") { copy(Issue.aiPrompt(for: picked)) }
                        .disabled(picked.isEmpty)
                        .help("Copy one prompt asking Claude Code to fix every checked issue")
                }
                .padding(.horizontal).padding(.vertical, 6)
            }
            Divider()
            if issues.isEmpty && !model.loading {
                ContentUnavailableView("Nothing to fix", systemImage: "checkmark.circle", description: Text("Every check passed."))
            } else {
                List(selection: $selection) {
                    ForEach([Issue.Severity.problem, .warning, .info], id: \.self) { sev in
                        let group = issues.filter { $0.severity == sev }
                        if !group.isEmpty {
                            SwiftUI.Section(sev == .problem ? "Problems" : sev == .warning ? "Warnings" : "Suggestions") {
                                ForEach(group) { issue in
                                    IssueRow(issue: issue, checked: Binding(
                                        get: { checked.contains(issue.id) },
                                        set: { if $0 { checked.insert(issue.id) } else { checked.remove(issue.id) } }
                                    )).tag(issue.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: issues.map(\.id)) { checked.formIntersection($1) }
        .onChange(of: selection) {
            guard let issue = issues.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(issue.title, term: issue.term,
                                  facts: [("Item", issue.subject), ("Section", issue.section.rawValue)] + (issue.tokens > 0 ? [("Context", formatTokens(issue.tokens))] : []) + (issue.bytes > 0 ? [("Disk", formatBytes(issue.bytes))] : []),
                                  file: issue.file, text: issue.detail)
            model.info?.prompt = issue.aiPrompt
        }
    }
}

struct Metric: View {
    let value: String
    let label: String
    let term: Term

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.semibold).monospacedDigit()).lineLimit(1).fixedSize()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .explains(term)
    }
}

struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    @Binding var checked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Include in bulk prompt", isOn: $checked).toggleStyle(.checkbox).labelsHidden()
                .help("Check to include this issue in one combined prompt")
            Image(systemName: issue.severity == .problem ? "exclamationmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "lightbulb")
                .foregroundStyle(issue.severity == .problem ? .red : issue.severity == .warning ? .orange : .secondary)
                .accessibilityLabel(issue.severity == .problem ? "Problem" : issue.severity == .warning ? "Warning" : "Suggestion")
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).fontWeight(.medium)
                Text(issue.subject).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if issue.tokens > 0 { Text(formatTokens(issue.tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if issue.bytes > 0 { Text(formatBytes(issue.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button("Copy AI Prompt", systemImage: "doc.on.clipboard") { copy(issue.aiPrompt) }
                .labelStyle(.iconOnly).help("Copy a prompt that asks Claude Code to fix this")
            if let fix = issue.fix {
                Button("Fix…") { model.propose(issue.title, fix) }.help(fix.summary)
            } else if let file = issue.file {
                Button("Open") { openFile(file) }.help("Open \(shortPath(file))")
            }
        }
        .padding(.vertical, 3)
        .help(issue.term.tooltip)
        .contextMenu { Button("Copy AI Prompt") { copy(issue.aiPrompt) } }
    }
}

struct ContextView: View {
    @Environment(AppModel.self) private var model
    @State private var project: String = ""

    var body: some View {
        let budget = model.startupBudget
        let projectRows = projectBudget
        let total = budget.reduce(0) { $0 + $1.tokens } + projectRows.reduce(0) { $0 + $1.tokens }
        let maxTokens = max(1, (budget.map(\.tokens) + projectRows.map(\.tokens)).max() ?? 1)
        Form {
            SwiftUI.Section {
                LabeledContent("Estimated before your first message", value: formatTokens(total))
                    .explains(.contextWindow)
                Text("Estimates use about 4 characters per token, plus the system prompt and tools, which are not counted here. Run /context inside Claude for exact numbers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Every session") {
                ForEach(budget, id: \.label) { row in
                    BudgetRow(label: row.label, note: row.note, tokens: row.tokens, max: maxTokens, term: row.term)
                }
            }
            SwiftUI.Section("In one project") {
                Picker("Project", selection: $project) {
                    Text("Choose…").tag("")
                    ForEach(model.snapshot.projects.filter(\.folderExists)) { Text(shortPath(URL(filePath: $0.path))).tag($0.path) }
                }
                ForEach(projectRows, id: \.label) { row in
                    BudgetRow(label: row.label, note: row.note, tokens: row.tokens, max: maxTokens, term: row.term)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var projectBudget: [(label: String, term: Term, tokens: Int, note: String)] {
        guard !project.isEmpty else { return [] }
        let s = model.snapshot
        let files = s.instructions.filter { $0.project == project }
        let md = files.filter { ($0.kind == .claudeMD || $0.kind == .localMD) }
        let rules = files.filter { $0.kind == .rule && !$0.pathScoped }
        let memory = files.filter { $0.kind == .memoryIndex }
        let parts = s.components.filter { $0.scope == .project && $0.owner == project }
        let projectMCP = s.mcpServers.filter { $0.project == project && ($0.scope == .local || $0.scope == .project) }.count
        return [
            ("CLAUDE.md files", .claudeMD, md.reduce(0) { $0 + $1.tokens }, "\(md.count) files"),
            ("Rules without paths:", .rules, rules.reduce(0) { $0 + $1.tokens }, "\(rules.count) always-loaded rules"),
            ("Project skills, agents & commands", .skillListing, parts.reduce(0) { $0 + $1.listingTokens }, "\(parts.count) in .claude/"),
            ("MEMORY.md (first 200 lines)", .autoMemory, memory.reduce(0) { $0 + $1.tokens }, memory.isEmpty ? "none" : "auto memory index"),
            ("Project MCP tool names", .mcpServer, projectMCP * 150, "\(projectMCP) servers (rough)"),
        ]
    }
}

struct BudgetRow: View {
    let label: String
    let note: String
    let tokens: Int
    let max: Int
    let term: Term

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(formatTokens(tokens)).monospacedDigit()
            }
            ProgressView(value: Double(tokens), total: Double(max)).progressViewStyle(.linear)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .explains(term)
        .accessibilityElement(children: .combine)
    }
}
