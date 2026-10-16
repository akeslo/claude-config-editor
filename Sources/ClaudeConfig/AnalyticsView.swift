import Charts
import ConfigCore
import SwiftUI

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SessionStats.ID?
    @State private var sort = [KeyPathComparator(\SessionStats.start, order: .reverse)]
    @State private var search = ""

    var body: some View {
        Group {
            if let report = model.analytics {
                content(report)
            } else {
                VStack(spacing: 10) {
                    ProgressView(value: model.analyticsProgress) { Text("Reading transcripts…") }
                        .frame(width: 280)
                    Text("The first run reads every transcript; later runs only read changed files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.loadAnalytics() }
        .toolbar {
            Button { Task { await model.loadAnalytics(force: true) } } label: { Label("Reload", systemImage: "arrow.clockwise.circle") }
                .help("Read transcripts again (only changed files are re-parsed)")
        }
    }

    @ViewBuilder private func content(_ r: AnalyticsReport) -> some View {
        let rows = r.sessions
            .filter { search.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(search) || $0.project.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 28) {
                        Metric(value: "\(r.sessions.count)", label: "sessions on disk", term: .transcripts)
                        Metric(value: compact(r.totalTokens), label: "tokens processed", term: .contextWindow)
                        Metric(value: r.cacheHitRate.formatted(.percent.precision(.fractionLength(0))), label: "input from cache", term: .contextWindow)
                            .help("Share of input tokens read from the prompt cache. Higher is cheaper and faster; it drops when sessions idle past the cache lifetime or the prompt prefix changes.")
                        Metric(value: "\(r.compactions)", label: "compactions", term: .contextWindow)
                            .help("Times a session hit its context limit and was summarized. Frequent compaction means long sessions or heavy startup context.")
                    }
                    Text("Covers transcripts still on disk; Claude deletes ones older than \(model.snapshot.cleanupPeriodDays) days.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 24) {
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
                    HStack(alignment: .top, spacing: 24) {
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
                .padding()
            }
            .frame(minHeight: 300)

            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("Session") { s in
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
            .searchable(text: $search, prompt: "Filter sessions by title or folder")
            .frame(minHeight: 200)
        }
        .onChange(of: selection) {
            guard let s = r.sessions.first(where: { $0.id == selection }) else { return }
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

    private func chartBox<C: View>(_ title: String, @ViewBuilder _ chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            chart().frame(height: 180)
        }
        .frame(maxWidth: .infinity)
    }

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
