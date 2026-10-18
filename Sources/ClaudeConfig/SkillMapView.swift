import Charts
import ConfigCore
import SwiftUI

/// Every skill, sliced by any dimension and drawn five ways. Facts are computed once per scan; controls only re-filter.
struct SkillMapView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("map.viz") private var viz = Viz.cloud
    @AppStorage("map.size") private var size = SkillMetric.uses
    @AppStorage("map.color") private var color = SkillDimension.source
    @AppStorage("map.group") private var groupRaw = ""
    @AppStorage("map.sort") private var sort = SortKey.metric
    @AppStorage("map.filter") private var filterJSON = ""
    @State private var facts: [SkillFacts] = []
    @State private var drill: [Drill] = []
    @State private var insight: SkillInsight?
    @State private var inspected: String?

    enum Viz: String, CaseIterable { case cloud = "Cloud", treemap = "Treemap", scatter = "Cost vs use", table = "Table", flow = "Flow" }
    enum SortKey: String, CaseIterable { case metric = "Size metric", name = "Name", uses = "Uses", tokens = "Tokens", recent = "Last used" }
    struct Drill: Hashable { let dim: SkillDimension; let value: String }

    private var group: SkillDimension? { SkillDimension(rawValue: groupRaw) }
    private var filter: SkillFilter {
        get {
            var f = (try? JSONDecoder().decode(SkillFilter.self, from: Data(filterJSON.utf8))) ?? SkillFilter()
            f.ids = insight?.ids
            return f
        }
        nonmutating set {
            var f = newValue; f.ids = nil
            filterJSON = (try? JSONEncoder().encode(f)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    var body: some View {
        let now = Date()
        let f = filter
        let visible = sorted(facts.filter { x in f.matches(x) && drill.allSatisfy { x.keys($0.dim).contains($0.value) } }, now: now)
        let colors = SkillPalette.colors(for: color, facts: facts)
        VStack(spacing: 0) {
            InsightStrip(insights: skillInsights(facts), active: $insight)
            controls(visible: visible)
            if !drill.isEmpty || insight != nil { breadcrumb }
            Divider()
            Group {
                if facts.isEmpty { ProgressView() }
                else if visible.isEmpty { ContentUnavailableView.search(text: f.search) }
                else {
                    switch viz {
                    case .cloud: CloudView(groups: skillGroups(visible, by: group, metric: size, now: now), size: size, color: color, colors: colors, now: now,
                                           onSkill: { inspected = $0 }, onGroup: groupTap)
                    case .treemap: TreemapView(groups: skillGroups(visible, by: group, metric: size, now: now), size: size, color: color, colors: colors, now: now,
                                               onSkill: { inspected = $0 }, onGroup: groupTap)
                    case .scatter: ScatterView(facts: visible, color: color, colors: colors, onSkill: { inspected = $0 })
                    case .table: SkillMapTable(facts: visible, now: now, onSkill: { inspected = $0 })
                    case .flow: FlowView(facts: visible, colors: SkillPalette.colors(for: .source, facts: facts),
                                         onNode: { dim, v in drill.append(Drill(dim: dim, value: v)) })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            legend(colors: colors, visible: visible)
        }
        .inspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
            if let id = inspected, let s = facts.first(where: { $0.id == id }) {
                SkillInspector(facts: s, all: facts).inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
        .task(id: model.skillFingerprint) {
            let comps = model.snapshot.components
            facts = await Task.detached { skillFacts(comps) }.value
        }
        .onChange(of: contextText(visible), initial: true) { model.skillMapContext = $1 }
        .onDisappear { model.skillMapContext = nil }
    }

    private func groupTap(_ key: String) { if let group { drill.append(Drill(dim: group, value: key)) } }

    private func sorted(_ xs: [SkillFacts], now: Date) -> [SkillFacts] {
        switch sort {
        case .metric: xs.sorted { ($0.value(size, now: now), $1.skill.name) > ($1.value(size, now: now), $0.skill.name) }
        case .name: xs.sorted { $0.skill.shortName.localizedLowercase < $1.skill.shortName.localizedLowercase }
        case .uses: xs.sorted { ($0.uses, $1.skill.name) > ($1.uses, $0.skill.name) }
        case .tokens: xs.sorted { ($0.tokens, $1.skill.name) > ($1.tokens, $0.skill.name) }
        case .recent: xs.sorted { ($0.skill.lastUsed ?? .distantPast) > ($1.skill.lastUsed ?? .distantPast) }
        }
    }

    private func contextText(_ visible: [SkillFacts]) -> String {
        skillMapContext(view: viz.rawValue, size: size, color: color, group: group, filter: filter,
                        drill: drill.map { ($0.dim, $0.value) }, visible: visible, total: facts.count)
    }

    // MARK: Control bar

    @ViewBuilder private func controls(visible: [SkillFacts]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Picker("View", selection: $viz) { ForEach(Viz.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Find a skill", text: Binding(get: { filter.search }, set: { var f = filter; f.search = $0; filter = f }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Text("\(visible.count) of \(facts.count) skills · \(visible.reduce(0) { $0 + $1.uses }) uses · \(formatTokens(visible.reduce(0) { $0 + $1.tokens })) tokens/session")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.m) {
                Picker("Size", selection: $size) { ForEach(SkillMetric.allCases, id: \.self) { Text($0.rawValue) } }.frame(width: 140)
                    .disabled(viz == .scatter || viz == .table || viz == .flow)
                Picker("Color", selection: $color) { ForEach(SkillDimension.allCases.filter { $0 != .project }, id: \.self) { Text($0.rawValue) } }.frame(width: 160)
                    .disabled(viz == .table || viz == .flow)
                Picker("Group", selection: $groupRaw) {
                    Text("None").tag("")
                    ForEach(SkillDimension.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .frame(width: 160).disabled(viz != .cloud && viz != .treemap)
                Picker("Sort", selection: $sort) { ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue) } }.frame(width: 150)
                    .disabled(viz != .cloud).help("Order within each group of the cloud; the table sorts by its column headers")
                Menu("Filters\(activeChipCount == 0 ? "" : " (\(activeChipCount))")", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(SkillDimension.allCases, id: \.self) { d in
                        Menu(d.rawValue) {
                            ForEach(values(d), id: \.self) { v in
                                Toggle(v, isOn: Binding(get: { filter.chips[d]?.contains(v) == true }, set: { _ in var f = filter; f.toggle(d, v); filter = f }))
                            }
                        }
                    }
                    Divider()
                    Button("Clear all filters") { filter = SkillFilter(); insight = nil; drill = [] }
                }
                .fixedSize()
                Spacer()
            }
            .pickerStyle(.menu)
            let chips = filter.chips.flatMap { d, vs in vs.map { (d, $0) } }.sorted { ($0.0.rawValue, $0.1) < ($1.0.rawValue, $1.1) }
            if !chips.isEmpty {
                HStack(spacing: Space.xs) {
                    ForEach(chips, id: \.1) { d, v in
                        Button { var f = filter; f.toggle(d, v); filter = f } label: {
                            Label("\(d.rawValue): \(v)", systemImage: "xmark.circle.fill").font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
    }

    private var activeChipCount: Int { filter.chips.values.reduce(0) { $0 + $1.count } }
    private func values(_ d: SkillDimension) -> [String] { Array(Set(facts.flatMap { $0.keys(d) })).sorted() }

    private var breadcrumb: some View {
        HStack(spacing: Space.xs) {
            Button("All skills") { drill = []; insight = nil }.buttonStyle(.link)
            if let insight {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Button(insight.kind.rawValue) { drill = [] }.buttonStyle(.link)
            }
            ForEach(Array(drill.enumerated()), id: \.offset) { i, d in
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Button("\(d.dim.rawValue): \(d.value)") { drill = Array(drill.prefix(i + 1)) }.buttonStyle(.link)
            }
            Spacer()
        }
        .font(.callout).padding(.horizontal, Space.l).padding(.bottom, Space.s)
    }

    private func legend(colors: [String: Color], visible: [SkillFacts]) -> some View {
        let shown = Set(visible.flatMap { $0.keys(color) })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.l) {
                Text("Color = \(color.rawValue)").fontWeight(.medium)
                ForEach(colors.keys.filter(shown.contains).sorted(), id: \.self) { k in
                    Label(k, systemImage: "circle.fill").foregroundStyle(colors[k] ?? .gray)
                }
                Text(viz == .scatter ? "x = tokens/session · y = uses · bubble = file size" : viz == .flow ? "Source → category → mode; band width = skills" :
                     viz == .table ? "Click a column to sort" : "Size = \(size.rawValue)\(viz == .cloud ? " · faded = call-only · struck = off" : "")")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).labelStyle(LegendLabel())
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        }
    }
}

extension AppModel {
    /// Changes when anything the map draws changes, so facts are rebuilt only then.
    var skillFingerprint: Int {
        var h = Hasher()
        for c in snapshot.components where c.kind == .skill { h.combine(c.id); h.combine(c.usageCount); h.combine(c.override); h.combine(c.alwaysLoaded); h.combine(c.agents.count) }
        return h.finalize()
    }
}

/// Stable colours per dimension value: fixed meanings where they exist, else a palette by frequency.
enum SkillPalette {
    static let palette: [Color] = [.blue, .orange, .green, .pink, .teal, .yellow, .purple, .red, .mint, .indigo, .brown, .cyan]
    static func colors(for d: SkillDimension, facts: [SkillFacts]) -> [String: Color] {
        switch d {
        case .source: return ["Personal": .primary, "Project": .orange, "Plugin": .purple, "Other agent": .teal]
        case .mode: return ["Automatic": .green, "Call-only": .blue, "Off": .gray]
        case .staleness: return ["Used recently": .green, "Stale": .orange, "Never used": .gray]
        case .usageBand: return Dictionary(uniqueKeysWithValues: zip(UsageBand.allCases.map(\.rawValue), [Color.red, .orange, .yellow, .gray]))
        default:
            var n: [String: Int] = [:]
            for f in facts { for k in f.keys(d) { n[k, default: 0] += 1 } }
            var out: [String: Color] = [:]
            for (i, k) in n.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).map(\.key).enumerated() {
                out[k] = ["—", "Other", "?"].contains(k) ? .gray : palette[i % palette.count]
            }
            return out
        }
    }
    static func color(_ f: SkillFacts, _ d: SkillDimension, _ map: [String: Color]) -> Color { map[f.keys(d).first ?? ""] ?? .gray }
}

// MARK: Insights

private struct InsightStrip: View {
    let insights: [SkillInsight]
    @Binding var active: SkillInsight?

    var body: some View {
        if !insights.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(insights) { i in
                        Button { active = active?.id == i.id ? nil : i } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(i.kind.rawValue, systemImage: icon(i.kind)).font(.caption.weight(.semibold))
                                Text(i.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                            .frame(maxWidth: 280, alignment: .leading)
                            .background(active?.id == i.id ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("\(i.detail)\nClick to show only these \(i.ids.count) skills")
                    }
                }
                .padding(.horizontal, Space.l).padding(.top, Space.s)
            }
        }
    }

    private func icon(_ k: SkillInsight.Kind) -> String {
        switch k { case .tokenHogs: "flame"; case .duplicates: "doc.on.doc"; case .stale: "clock.badge.exclamationmark"; case .topPerCategory: "star" }
    }
}

// MARK: Cloud

private struct CloudView: View {
    let groups: [(key: String, items: [SkillFacts])]
    let size: SkillMetric, color: SkillDimension
    let colors: [String: Color]
    let now: Date
    let onSkill: (String) -> Void, onGroup: (String) -> Void

    var body: some View {
        let mx = max(groups.flatMap(\.items).map { $0.value(size, now: now) }.max() ?? 1, 1)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.l) {
                ForEach(groups, id: \.key) { g in
                    VStack(alignment: .leading, spacing: Space.s) {
                        if groups.count > 1 {
                            Button { onGroup(g.key) } label: {
                                Label("\(g.key)  \(g.items.count)", systemImage: "chevron.right.circle").font(.headline)
                            }
                            .buttonStyle(.plain).help("Drill into \(g.key)")
                        }
                        FlowLayout(spacing: 10) {
                            ForEach(g.items) { f in
                                Button { onSkill(f.id) } label: {
                                    (Text(f.skill.shortName) + Text(" \(Int(f.value(size, now: now)))").font(.caption2.monospacedDigit()).foregroundColor(.secondary))
                                        .font(.system(size: 11 + 25 * log(1 + f.value(size, now: now)) / log(1 + mx)))
                                        .foregroundStyle(SkillPalette.color(f, color, colors))
                                        .opacity(f.skill.state == .off ? 0.35 : f.skill.state == .onDemand ? 0.7 : 1)
                                        .strikethrough(f.skill.state == .off)
                                }
                                .buttonStyle(.plain)
                                .help("/\(f.skill.name) · \(f.uses) uses · \(formatTokens(f.tokens)) tokens · \(f.freshness)")
                            }
                        }
                    }
                }
            }
            .padding(Space.l)
        }
    }
}

// MARK: Treemap

private struct TreemapView: View {
    let groups: [(key: String, items: [SkillFacts])]
    let size: SkillMetric, color: SkillDimension
    let colors: [String: Color]
    let now: Date
    let onSkill: (String) -> Void, onGroup: (String) -> Void

    var body: some View {
        let zero = groups.flatMap(\.items).filter { $0.value(size, now: now) <= 0 }.count
        VStack(spacing: 0) {
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: Space.s, dy: Space.s)
                let totals = groups.map { $0.items.reduce(0) { $0 + $1.value(size, now: now) } }
                let outer = squarify(totals, in: bounds)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(groups.enumerated()), id: \.element.key) { gi, g in
                        let r = outer[gi]
                        if r.width > 2, r.height > 2 {
                            let header: CGFloat = groups.count > 1 && r.height > 40 ? 18 : 0
                            let inner = CGRect(x: r.minX + 2, y: r.minY + header + 2, width: max(0, r.width - 4), height: max(0, r.height - header - 4))
                            let rects = squarify(g.items.map { $0.value(size, now: now) }, in: inner)
                            ForEach(Array(g.items.enumerated()), id: \.element.id) { i, f in
                                let c = rects[i]
                                if c.width > 1, c.height > 1 {
                                    Block(f: f, rect: c, fill: SkillPalette.color(f, color, colors)).onTapGesture { onSkill(f.id) }
                                }
                            }
                            if header > 0 {
                                Text("\(g.key) · \(g.items.count)").font(.caption.weight(.semibold)).lineLimit(1)
                                    .frame(width: r.width - 4, height: header, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onGroup(g.key) }
                                    .help("Drill into \(g.key)")
                                    .offset(x: r.minX + 4, y: r.minY)
                            }
                            Rectangle().stroke(.separator, lineWidth: 1).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
                        }
                    }
                }
            }
            if zero > 0 {
                Text("\(zero) skills with zero \(size.rawValue.lowercased()) have no area").font(.caption).foregroundStyle(.secondary).padding(.bottom, Space.xs)
            }
        }
    }

    private struct Block: View {
        let f: SkillFacts, rect: CGRect, fill: Color
        var body: some View {
            RoundedRectangle(cornerRadius: 3).fill(fill.opacity(f.skill.state == .always ? 0.55 : 0.3))
                .overlay(alignment: .topLeading) {
                    if rect.width > 40, rect.height > 16 {
                        Text(f.skill.shortName).font(.system(size: min(14, max(9, rect.height / 4)))).lineLimit(1).padding(3)
                    }
                }
                .frame(width: max(0, rect.width - 1), height: max(0, rect.height - 1))
                .contentShape(Rectangle())
                .help("/\(f.skill.name) · \(f.uses) uses · \(formatTokens(f.tokens)) tokens")
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

// MARK: Scatter

private struct ScatterView: View {
    let facts: [SkillFacts]
    let color: SkillDimension
    let colors: [String: Color]
    let onSkill: (String) -> Void

    var body: some View {
        let tSplit = median(facts.map(\.tokens)), uSplit = median(facts.map(\.uses))
        let quads = Dictionary(grouping: facts) { Quadrant(tokens: $0.tokens, uses: $0.uses, tokenSplit: tSplit, useSplit: uSplit) }
        let domain = colors.keys.sorted()
        VStack(alignment: .leading, spacing: Space.s) {
            Chart {
                ForEach(facts) { f in
                    PointMark(x: .value("Tokens", f.tokens), y: .value("Uses", f.uses))
                        .symbolSize(.init(20 + min(Double(f.fileBytes) / 60, 400)))
                        .foregroundStyle(by: .value(color.rawValue, f.keys(color).first ?? "—"))
                        .opacity(0.75)
                }
                RuleMark(x: .value("Token split", tSplit)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
                RuleMark(y: .value("Use split", uSplit)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
            }
            .chartForegroundStyleScale(domain: domain, range: domain.map { colors[$0] ?? .gray })
            .chartLegend(.hidden)
            .chartYScale(type: .symmetricLog)
            .chartXAxisLabel("Always-on tokens per session")
            .chartYAxisLabel("Times used")
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                    ZStack {
                        quadLabel(.expensiveUnused, quads).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        quadLabel(.expensiveUsed, quads).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        quadLabel(.cheapUsed, quads).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        quadLabel(.cheapUnused, quads).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .padding(Space.s).frame(width: plot.width, height: plot.height).offset(x: plot.minX, y: plot.minY).allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: plot.width, height: plot.height).offset(x: plot.minX, y: plot.minY)
                        .onTapGesture { p in if let id = nearest(p, proxy) { onSkill(id) } }
                }
            }
            .padding(Space.l)
            Text("Splits at the median: \(formatTokens(tSplit)) tokens, \(uSplit) uses. Click a bubble for details.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Space.l).padding(.bottom, Space.s)
        }
    }

    private func nearest(_ p: CGPoint, _ proxy: ChartProxy) -> String? {
        var best: (String, CGFloat)?
        for f in facts {
            guard let q = proxy.position(for: (f.tokens, f.uses)) else { continue }
            let d: CGFloat = hypot(q.x - p.x, q.y - p.y)
            if d < 24, d < (best?.1 ?? .infinity) { best = (f.id, d) }
        }
        return best?.0
    }

    private func quadLabel(_ q: Quadrant, _ quads: [Quadrant: [SkillFacts]]) -> some View {
        Text("\(q.rawValue) · \(quads[q]?.count ?? 0)").font(.caption.weight(.semibold))
            .foregroundStyle(q == .expensiveUnused ? Color.red : .secondary)
            .padding(4).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: Table

private struct MapRow: Identifiable {
    let f: SkillFacts
    let now: Date
    var id: String { f.id }
    var name: String { f.skill.name }
    var source: String { f.keys(.source)[0] }
    var category: String { f.category }
    var mode: String { f.keys(.mode)[0] }
    var uses: Int { f.uses }
    var tokens: Int { f.tokens }
    var lastUsed: Date { f.skill.lastUsed ?? .distantPast }
    var agents: Int { f.skill.agents.count }
    var bytes: Int { f.fileBytes }
    var freshness: String { f.freshness }
    var band: String { UsageBand(uses: f.uses).rawValue }
    var overlaps: Int { f.overlaps.count }
}

private struct SkillMapTable: View {
    let facts: [SkillFacts]
    let now: Date
    let onSkill: (String) -> Void
    @State private var order = [KeyPathComparator(\MapRow.uses, order: .reverse)]
    @State private var selection: String?

    var body: some View {
        let rows = facts.map { MapRow(f: $0, now: now) }.sorted(using: order)
        Table(rows, selection: $selection, sortOrder: $order) {
            Group {
                TableColumn("Skill", value: \MapRow.name) { (r: MapRow) in Text("/" + r.name).font(.body.monospaced()).lineLimit(1) }.width(min: 140, ideal: 220)
                TableColumn("Source", value: \MapRow.source) { (r: MapRow) in Text(r.source) }.width(min: 60, ideal: 80)
                TableColumn("Category", value: \MapRow.category) { (r: MapRow) in Text(r.category) }.width(min: 80, ideal: 120)
                TableColumn("Mode", value: \MapRow.mode) { (r: MapRow) in Text(r.mode) }.width(min: 60, ideal: 80)
                TableColumn("Uses", value: \MapRow.uses) { (r: MapRow) in Text(String(r.uses)).monospacedDigit() }.width(min: 40, ideal: 50)
                TableColumn("Tokens", value: \MapRow.tokens) { (r: MapRow) in Text(formatTokens(r.tokens)).monospacedDigit() }.width(min: 45, ideal: 55)
            }
            Group {
                TableColumn("Last used", value: \MapRow.lastUsed) { (r: MapRow) in Text(relative(r.f.skill.lastUsed)).foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                TableColumn("Agents", value: \MapRow.agents) { (r: MapRow) in Text(String(r.agents)).monospacedDigit() }.width(min: 40, ideal: 50)
                TableColumn("Size", value: \MapRow.bytes) { (r: MapRow) in Text(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)) }.width(min: 50, ideal: 65)
                TableColumn("Freshness", value: \MapRow.freshness) { (r: MapRow) in Text(r.freshness) }.width(min: 70, ideal: 90)
                TableColumn("Band", value: \MapRow.band) { (r: MapRow) in Text(r.band) }.width(min: 70, ideal: 100)
                TableColumn("Overlaps", value: \MapRow.overlaps) { (r: MapRow) in Text(r.overlaps == 0 ? "—" : String(r.overlaps)) }.width(min: 50, ideal: 60)
            }
        }
        .onChange(of: selection) { if let selection { onSkill(selection) } }
    }
}

// MARK: Flow (Sankey)

private struct FlowView: View {
    let facts: [SkillFacts]
    let colors: [String: Color]
    let onNode: (SkillDimension, String) -> Void
    static let dims: [SkillDimension] = [.source, .category, .mode]

    struct Node { let col: Int; let key: String; let count: Int; var rect: CGRect }

    /// Columns of stacked nodes, heights proportional to skill count.
    static func layout(_ facts: [SkillFacts], in r: CGRect) -> [[Node]] {
        let gap: CGFloat = 8, w: CGFloat = 14, n = CGFloat(max(facts.count, 1))
        return dims.enumerated().map { ci, d in
            let counts = Dictionary(grouping: facts) { $0.keys(d)[0] }.map { ($0.key, $0.value.count) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
            let usable = r.height - gap * CGFloat(max(counts.count - 1, 0))
            let x = r.minX + (r.width - w) * CGFloat(ci) / CGFloat(dims.count - 1)
            var y = r.minY
            return counts.map { k, c in
                let h = usable * CGFloat(c) / n
                defer { y += h + gap }
                return Node(col: ci, key: k, count: c, rect: CGRect(x: x, y: y, width: w, height: h))
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 140, dy: Space.l)
            let cols = Self.layout(facts, in: area)
            let flows = skillFlows(facts)
            let n = CGFloat(max(facts.count, 1))
            Canvas { ctx, _ in
                for (stage, links) in flows.enumerated() {
                    var outY: [String: CGFloat] = [:], inY: [String: CGFloat] = [:]
                    for l in links {
                        guard let a = cols[stage].first(where: { $0.key == l.from }), let b = cols[stage + 1].first(where: { $0.key == l.to }) else { continue }
                        let h = a.rect.height * CGFloat(l.count) / CGFloat(a.count)
                        let hb = b.rect.height * CGFloat(l.count) / CGFloat(b.count)
                        let y0 = a.rect.minY + outY[l.from, default: 0], y1 = b.rect.minY + inY[l.to, default: 0]
                        outY[l.from, default: 0] += h; inY[l.to, default: 0] += hb
                        let x0 = a.rect.maxX, x1 = b.rect.minX, mid = (x0 + x1) / 2
                        var p = Path()
                        p.move(to: CGPoint(x: x0, y: y0))
                        p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
                        p.addLine(to: CGPoint(x: x1, y: y1 + hb))
                        p.addCurve(to: CGPoint(x: x0, y: y0 + h), control1: CGPoint(x: mid, y: y1 + hb), control2: CGPoint(x: mid, y: y0 + h))
                        p.closeSubpath()
                        let src = stage == 0 ? l.from : nil
                        ctx.fill(p, with: .color((src.flatMap { colors[$0] } ?? .accentColor).opacity(0.25)))
                    }
                }
                for col in cols {
                    for node in col {
                        ctx.fill(Path(node.rect), with: .color(node.col == 0 ? colors[node.key] ?? .gray : .secondary))
                        let label = Text("\(node.key) \(node.count)").font(.caption)
                        if node.col == 0 { ctx.draw(label, at: CGPoint(x: node.rect.minX - 6, y: node.rect.midY), anchor: .trailing) }
                        else { ctx.draw(label, at: CGPoint(x: node.rect.maxX + 6, y: node.rect.midY), anchor: .leading) }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                for col in cols { for node in col where node.rect.insetBy(dx: -8, dy: 0).contains(p) { onNode(Self.dims[node.col], node.key) } }
            }
            .help("Click a column bar to drill into it · \(Int(n)) skills")
        }
    }
}

// MARK: Inspector

struct SkillInspector: View {
    @Environment(AppModel.self) private var model
    let facts: SkillFacts
    let all: [SkillFacts]
    @State private var text: String?

    var body: some View {
        let s = facts.skill
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("/" + s.name).font(.title3.weight(.semibold).monospaced()).textSelection(.enabled)
                Text(s.description).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: 4) {
                    row("Source", s.belongsTo)
                    if s.scope == .plugin { row("Plugin", s.owner ?? "?") }
                    row("Category", facts.category)
                    row("Mode", SkillFacts.mode(s.state))
                    row("Token cost", s.state == .always ? "\(formatTokens(facts.tokens)) per session" : "0 (would be \(formatTokens(s.tokens(in: .always))) if automatic)")
                    row("Uses", "\(facts.uses) · \(UsageBand(uses: facts.uses).rawValue)")
                    row("Last used", s.lastUsed.map { "\(relative($0)) (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? "never")
                    row("Freshness", facts.freshness)
                    row("File size", ByteCountFormatter.string(fromByteCount: Int64(facts.fileBytes), countStyle: .file))
                    row("Agents", s.agents.map(\.rawValue).joined(separator: ", "))
                }
                .font(.callout)
                Text("Usage over time isn't available: Claude Code records only a use count and the last-used time per skill.")
                    .font(.caption).foregroundStyle(.secondary)
                if s.ownsFile { StatePicker(model: model, skill: s) }
                section("Locations") {
                    ForEach([s.file] + s.locations, id: \.self) { u in
                        HStack {
                            Text(shortPath(u)).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Copy", systemImage: "doc.on.doc") { copy(u.path) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            Button("Reveal", systemImage: "folder") { reveal(u) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("Open in editor") { openFile(s.file) }
                    Button(model.pickedSkills.contains(s.id) ? "Remove from Copy prompt" : "Add to Copy prompt") {
                        if model.pickedSkills.remove(s.id) == nil { model.pickedSkills.insert(s.id) }
                    }
                    .help("The selection used by Copy prompt on By category")
                }
                .controlSize(.small)
                if s.ownsFile {
                    Button("Uninstall…", systemImage: "trash") { model.proposeTrash([trashURL(s)]) }
                        .controlSize(.small).help("Moves the skill folder to the Trash after you confirm")
                }
                let over = all.filter { facts.overlaps.contains($0.id) }
                if !over.isEmpty {
                    section("Overlaps with") {
                        ForEach(over) { o in Text("/\(o.skill.name) · \(o.skill.belongsTo) · \(o.uses) uses").font(.caption) }
                    }
                }
                if let text {
                    let parts = splitFrontmatter(text)
                    if !parts.frontmatter.isEmpty {
                        section("Frontmatter") {
                            Text(parts.frontmatter).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    section("SKILL.md") {
                        Text((try? AttributedString(markdown: String(parts.body.prefix(20_000)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(parts.body))
                            .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Space.l)
        }
        .task(id: s.id) { text = try? String(contentsOf: s.file, encoding: .utf8) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v).textSelection(.enabled) }
    }
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) { Text(title).font(.headline); content() }
    }
}

private struct LegendLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// Left-to-right wrapping layout for the words.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 800, subviews)
        return CGSize(width: proposal.width ?? 800, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + (row.height - s.height) / 2), proposal: .unspecified)
            }
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] {
        var rows: [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] = []
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { rows.append((y, h, items)); y += h + spacing; x = 0; h = 0; items = [] }
            items.append((i, x)); x += s.width + spacing; h = max(h, s.height)
        }
        if !items.isEmpty { rows.append((y, h, items)) }
        return rows
    }
}
