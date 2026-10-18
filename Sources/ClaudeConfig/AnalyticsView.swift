import Charts
import ConfigCore
import SwiftUI

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var sel = BulkSelection<String>()
    @State private var sort = [KeyPathComparator(\SessionStats.start, order: .reverse)]
    @State private var search = ""
    @State private var agent = "all"
    @State private var modelSort = [KeyPathComparator(\ModelRow.cost, order: .reverse)]

    struct ModelRow: Identifiable {
        let model: String
        var id: String { model }
        let input, output, create, read: Int
        let cost: Double
    }

    var body: some View {
        Group {
            if let report = model.analytics {
                content(report)
            } else {
                LoadingState(title: "Reading transcripts…", detail: "The first run reads every transcript; later runs only read changed files.", progress: model.analyticsProgress)
            }
        }
        .task { await model.loadAnalytics() }
        .task { await model.loadUsage() }
        .toolbar {
            Button { Task { await model.loadAnalytics(force: true); await model.loadUsage(force: true) } } label: { Label("Reload", systemImage: "arrow.clockwise.circle") }
                .help("Read transcripts and run ccusage again (only changed transcripts are re-parsed)")
        }
    }

    @ViewBuilder private func content(_ r: AnalyticsReport) -> some View {
        let rows = r.sessions
            .filter { search.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(search) || $0.project.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        let picked = r.sessions.filter { sel.contains($0.id) }
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    cost
                    HStack(alignment: .firstTextBaseline) { Text("Transcripts").font(.title3.weight(.semibold)); Spacer(); SourceTag("transcripts") }.padding(.top, Space.s)
                    HStack(spacing: Space.m) {
                        Card { Metric(value: "\(r.sessions.count)", label: "sessions on disk", term: .transcripts) }
                        Card { Metric(value: compact(r.totalTokens), label: "tokens processed", term: .contextWindow) }
                        Card {
                            Metric(value: r.cacheHitRate.formatted(.percent.precision(.fractionLength(0))), label: "input from cache", term: .contextWindow)
                                .help("Share of input tokens read from the prompt cache. Higher is cheaper and faster; it drops when sessions idle past the cache lifetime or the prompt prefix changes.")
                        }
                        Card {
                            Metric(value: "\(r.compactions)", label: "compactions", term: .contextWindow)
                                .help("Times a session hit its context limit and was summarized. Frequent compaction means long sessions or heavy startup context.")
                        }
                    }
                    Text("Covers transcripts still on disk; Claude deletes ones older than \(model.snapshot.cleanupPeriodDays) days.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: Space.l) {
                        chartBox("Tokens per day (last 60 days)") {
                            Chart(r.perDay(), id: \.day) {
                                BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Tokens", $0.tokens))
                            }
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(compact(v.as(Int.self) ?? 0)) } } }
                        }
                        chartBox("Peak context per session") {
                            Chart(histogram(r.sessions.map(\.peakContext)), id: \.label) {
                                BarMark(x: .value("Peak", $0.label), y: .value("Sessions", $0.count))
                            }
                        }
                        .help("The largest prompt each session sent. Sessions near the model's window are the ones that compact.")
                    }
                    HStack(alignment: .top, spacing: Space.l) {
                        chartBox("Most used tools") {
                            Chart(r.topTools(12), id: \.name) {
                                BarMark(x: .value("Calls", $0.count), y: .value("Tool", $0.name))
                            }
                        }
                        chartBox("Requests by model") {
                            Chart(r.modelMix(), id: \.model) {
                                BarMark(x: .value("Requests", $0.requests), y: .value("Model", $0.model))
                            }
                        }
                    }
                }
                .padding(Space.l)
            }
            .frame(minHeight: 300)

            Table(rows, selection: $sel.ids, sortOrder: $sort) {
                TableColumn("", value: \SessionStats.duration) { (s: SessionStats) in SelectBox(sel: $sel, id: s.id, visible: rows.map(\.id), name: s.title ?? s.id) }.width(22)
                TableColumn("Session", value: \SessionStats.duration) { (s: SessionStats) in
                    VStack(alignment: .leading) {
                        Text(s.title ?? s.id).lineLimit(1)
                        Text(shortPath(URL(filePath: s.project))).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                TableColumn("Started", value: \.start, comparator: OptionalDateComparator()) { Text(relative($0.start)) }.width(110)
                TableColumn("Length", value: \.duration) { Text(Duration.seconds($0.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow))) }.width(70)
                TableColumn("Prompts", value: \.userPrompts) { Text("\($0.userPrompts)").monospacedDigit() }.width(60)
                TableColumn("Peak context", value: \.peakContext) { Text(compact($0.peakContext)).monospacedDigit() }.width(90)
                TableColumn("Compactions", value: \.compactions) { s in Text("\(s.compactions)").monospacedDigit().foregroundStyle(s.compactions > 0 ? .orange : .primary) }.width(85)
                TableColumn("Tokens", value: \.totalTokens) { Text(compact($0.totalTokens)).monospacedDigit() }.width(70)
            }
            .contextMenu(forSelectionType: SessionStats.ID.self) { ids in
                TrashButton(urls: r.sessions.filter { ids.contains($0.id) }.map { URL(filePath: $0.file) })
            }
            .bulkSelectable($sel, visible: rows.map(\.id), actions: [
                BulkAction(title: "Copy resume commands", icon: "doc.on.clipboard", check: bulkCheck(picked) { _ in nil }) {
                    copy(picked.compactMap { resumeCommand(project: $0.project, id: $0.id) }.joined(separator: "\n"))
                },
                BulkAction(title: "Export list…", icon: "square.and.arrow.up", check: bulkCheck(picked) { _ in nil }) {
                    exportCSV("sessions.csv", header: ["id", "title", "folder", "started", "prompts", "peak context", "compactions", "tokens"],
                              rows: picked.map { [$0.id, $0.title ?? "", $0.project, $0.start?.formatted() ?? "", "\($0.userPrompts)", "\($0.peakContext)", "\($0.compactions)", "\($0.totalTokens)"] })
                },
                BulkAction(title: "Move transcripts to Trash…", icon: "trash", check: bulkCheck(picked) { _ in nil }) {
                    model.proposeBulk("Move \(picked.count) transcript\(picked.count == 1 ? "" : "s") to the Trash",
                                      bulkPlan(picked, label: { $0.title ?? $0.id }, skip: { trashRefusal(URL(filePath: $0.file)) }) { .trash([URL(filePath: $0.file)]) })
                },
            ])
            .searchable(text: $search, prompt: "Filter sessions by title or folder")
            .frame(minHeight: 200)
        }
        .onChange(of: sel.ids) {
            guard sel.count == 1, let s = r.sessions.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem(s.title ?? s.id, term: .transcripts, facts: [
                ("Folder", shortPath(URL(filePath: s.project))), ("Model", s.mainModel),
                ("Requests", "\(s.requests)"), ("Prompts", "\(s.userPrompts)"),
                ("Peak context", compact(s.peakContext)),
                ("Compactions", "\(s.compactions)" + (s.compactions > 0 ? " (dropped \(compact(s.tokensDroppedByCompaction)))" : "")),
                ("Input / cache read", "\(compact(s.inputTokens + s.cacheWriteTokens)) / \(compact(s.cacheReadTokens))"),
                ("Output", compact(s.outputTokens)),
            ], file: URL(filePath: s.file),
            text: "Top tools:\n" + s.tools.sorted { $0.value > $1.value }.prefix(10).map { "\($0.value)×  \($0.key)" }.joined(separator: "\n") + "\n\nResume with: claude --resume \(s.id)")
        }
    }

    private func chartBox<C: View>(_ title: String, source: String = "transcripts", @ViewBuilder _ chart: () -> C) -> some View {
        Card(title: title, source: source) { chart().frame(height: 180) }
    }

    // MARK: Cost (ccusage)

    @ViewBuilder private var cost: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cost & tokens").font(.title3.weight(.semibold))
            SourceTag("ccusage")
            Spacer()
            Picker("Agent", selection: $agent) {
                ForEach(["all", "claude", "codex", "gemini"], id: \.self) { Text($0 == "all" ? "All agents" : $0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Which coding agent's usage to count, as ccusage detects it")
        }
        switch model.usage {
        case nil:
            Card(source: "ccusage") { LoadingState(title: "Running ccusage…", detail: "npx -y ccusage@latest daily --json").frame(height: 120) }
        case .failure(.noNode):
            Card(source: "ccusage") {
                ContentUnavailableView {
                    Label("Install Node to see cost", systemImage: "dollarsign.circle")
                } description: {
                    Text("Cost comes from ccusage, which runs with npx. Install Node (for example with brew install node), then rescan with ⌘R.")
                }
            }
        case .failure(.failed(let why)):
            Card(source: "ccusage") {
                ContentUnavailableView("ccusage didn't return a report", systemImage: "exclamationmark.triangle", description: Text("\(why). Rescan with ⌘R to try again."))
            }
        case .success(let u):
            let a = agent == "all" ? nil : agent
            HStack(spacing: Space.m) {
                costTile(u.rows(lastDays: 1, agent: a), "today", tint: .spark)
                costTile(u.rows(lastDays: 7, agent: a), "last 7 days")
                costTile(u.rows(lastDays: 30, agent: a), "last 30 days")
                costTile(u.rows(lastDays: nil, agent: a), "all time")
            }
            let month = u.rows(lastDays: 30, agent: a)
            Card(title: "Cost per day, last 30 days", source: "ccusage") {
                if month.isEmpty {
                    Text("No usage in the last 30 days for this agent.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Chart(month) {
                        BarMark(x: .value("Day", day($0.day), unit: .day), y: .value("Cost", $0.cost))
                            .foregroundStyle(by: .value("Model", $0.model))
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(usd(v.as(Double.self) ?? 0)) } } }
                    .frame(height: 200)
                }
            }
            modelTable(u.rows(lastDays: nil, agent: a))
        }
    }

    private func costTile(_ rows: [UsageRow], _ label: String, tint: Color? = nil) -> some View {
        Card {
            Metric(value: usd(rows.reduce(0) { $0 + $1.cost }), label: label, term: .transcripts, tint: tint)
            Text("\(compact(rows.reduce(0) { $0 + $1.tokens })) tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help("Estimated API-price cost of \(label), computed by ccusage from local transcripts")
    }

    private func modelTable(_ rows: [UsageRow]) -> some View {
        let models = Dictionary(grouping: rows, by: \.model)
            .map { m, r in ModelRow(model: m, input: r.reduce(0) { $0 + $1.input }, output: r.reduce(0) { $0 + $1.output },
                                    create: r.reduce(0) { $0 + $1.cacheCreate }, read: r.reduce(0) { $0 + $1.cacheRead }, cost: r.reduce(0) { $0 + $1.cost }) }
            .filter { search.isEmpty || $0.model.localizedCaseInsensitiveContains(search) }
            .sorted(using: modelSort)
        return Card(title: "By model, all time", source: "ccusage") {
            Table(models, sortOrder: $modelSort) {
                TableColumn("Model", value: \.model) { Text($0.model) }
                TableColumn("Input", value: \.input) { Text(compact($0.input)).monospacedDigit() }.width(80)
                TableColumn("Output", value: \.output) { Text(compact($0.output)).monospacedDigit() }.width(80)
                TableColumn("Cache write", value: \.create) { Text(compact($0.create)).monospacedDigit() }.width(80)
                TableColumn("Cache read", value: \.read) { Text(compact($0.read)).monospacedDigit() }.width(80)
                TableColumn("Cost", value: \.cost) { Text(usd($0.cost)).fontWeight(.medium).monospacedDigit() }.width(80)
            }
            .frame(height: CGFloat(models.count) * 24 + 32)
        }
    }

    private func day(_ s: String) -> Date {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .distantPast }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? .distantPast
    }
}

func usd(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2))) }

private extension AnalyticsView {

    private func histogram(_ values: [Int]) -> [(label: String, count: Int)] {
        let buckets = [(0, "<50k"), (50_000, "50k+"), (100_000, "100k+"), (200_000, "200k+"), (500_000, "500k+")]
        return buckets.enumerated().map { i, b in
            let upper = i + 1 < buckets.count ? buckets[i + 1].0 : .max
            return (b.1, values.filter { $0 >= b.0 && $0 < upper }.count)
        }
    }
}

func compact(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }

struct OptionalDateComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let r = (a ?? .distantPast).compare(b ?? .distantPast)
        return order == .forward ? r : (r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : .orderedSame)
    }
}
