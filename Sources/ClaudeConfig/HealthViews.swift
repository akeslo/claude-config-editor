import ConfigCore
import SwiftUI

struct Metric: View {
    let value: String
    let label: String
    let term: Term
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(value).font(.metric).foregroundStyle(tint ?? .primary).lineLimit(1).fixedSize()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .explains(term)
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
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                Card(source: "config files, ≈4 chars per token") {
                    Metric(value: formatTokens(total), label: "estimated before your first message", term: .contextWindow, tint: .brand)
                    Text("Estimates use about 4 characters per token, plus the system prompt and tools, which are not counted here. Run /context inside Claude for exact numbers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: Space.l) {
                    Card(title: "Every session") {
                        ForEach(budget, id: \.label) { row in
                            BudgetRow(label: row.label, note: row.note, tokens: row.tokens, max: maxTokens, term: row.term)
                        }
                    }
                    Card(title: "In one project") {
                        Picker("Project", selection: $project) {
                            Text("Choose…").tag("")
                            ForEach(model.snapshot.projects.filter(\.folderExists)) { Text(shortPath(URL(filePath: $0.path))).tag($0.path) }
                        }
                        if projectRows.isEmpty {
                            Text("Choose a project to add what it loads on top.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(projectRows, id: \.label) { row in
                            BudgetRow(label: row.label, note: row.note, tokens: row.tokens, max: maxTokens, term: row.term)
                        }
                    }
                }
            }
            .padding(Space.l)
        }
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
        VStack(alignment: .leading, spacing: Space.xs) {
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
