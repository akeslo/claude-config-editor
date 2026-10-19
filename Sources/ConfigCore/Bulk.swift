import Foundation

// One bulk-selection model for every list screen: selection, which actions apply, the plan the confirm sheet previews,
// and the per-item results afterwards. Views only render it.

/// Selected ids plus the anchor for shift-click ranges. Ids outside the visible (filtered) list stay selected.
public struct BulkSelection<ID: Hashable>: Equatable {
    public var ids: Set<ID> = []
    public var anchor: ID?
    public init(_ ids: Set<ID> = []) { self.ids = ids }

    public enum Click { case toggle, range }
    public enum Header: Equatable { case none, some, all }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// Checkbox click: toggle (plain or ⌘), or ⇧ to set every visible row from the anchor to `id` to the new state of `id`.
    public mutating func click(_ id: ID, visible: [ID], _ mode: Click = .toggle) {
        let on = !ids.contains(id)
        if mode == .range, let a = anchor, let i = visible.firstIndex(of: a), let j = visible.firstIndex(of: id) {
            for x in visible[min(i, j)...max(i, j)] { if on { ids.insert(x) } else { ids.remove(x) } }
        } else if on { ids.insert(id) } else { ids.remove(id) }
        anchor = id
    }

    /// ⌘A: adds every visible row (keeps hidden selections).
    public mutating func selectAll(_ visible: [ID]) { ids.formUnion(visible) }
    public mutating func clear() { ids = []; anchor = nil }
    /// Header checkbox: all visible selected → unselect them; otherwise select all visible.
    public mutating func toggleAll(_ visible: [ID]) {
        if header(visible) == .all { ids.subtract(visible) } else { selectAll(visible) }
    }
    public func header(_ visible: [ID]) -> Header {
        let n = visible.filter(ids.contains).count
        return n == 0 ? .none : n == visible.count ? .all : .some
    }
    /// Selected rows the current filter hides.
    public func hiddenCount(_ visible: [ID]) -> Int { ids.subtracting(visible).count }
    public func label(_ visible: [ID]) -> String {
        let h = hiddenCount(visible)
        return "\(count) selected" + (h > 0 ? " · \(h) hidden by filter" : "")
    }
}

/// Whether an action applies to the whole selection; `why` is the tooltip when it doesn't.
public struct BulkCheck: Equatable, Sendable {
    public let enabled: Bool
    public let why: String?
    public init(enabled: Bool, why: String?) { self.enabled = enabled; self.why = why }
    public static let ok = BulkCheck(enabled: true, why: nil)
}

/// Disabled when any item is blocked; the tooltip counts each reason, e.g. "3 of 5 are plugin skills".
/// `blocked` returns a predicate phrase ("are plugin skills") or nil when the item can take the action.
public func bulkCheck<T>(_ items: [T], blocked: (T) -> String?) -> BulkCheck {
    guard !items.isEmpty else { return .init(enabled: false, why: "Nothing selected") }
    var counts: [String: Int] = [:]
    for r in items.compactMap(blocked) { counts[r, default: 0] += 1 }
    guard !counts.isEmpty else { return .ok }
    let why = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.value) of \(items.count) \($0.key)" }.joined(separator: "; ")
    return .init(enabled: false, why: why)
}

/// One item of a bulk change: its fix, or why it is skipped.
public struct BulkStep: Sendable {
    public let label: String
    public let fix: Fix?
    public let skip: String?
    public init(label: String, fix: Fix?, skip: String? = nil) { self.label = label; self.fix = fix; self.skip = skip }
}

/// Builds the per-item plan. A skip reason wins; an item with no fix and no reason is skipped as "nothing to change".
public func bulkPlan<T>(_ items: [T], label: (T) -> String, skip: (T) -> String? = { _ in nil }, fix: (T) -> Fix?) -> [BulkStep] {
    items.map { i in
        if let s = skip(i) { return BulkStep(label: label(i), fix: nil, skip: s) }
        guard let f = fix(i) else { return BulkStep(label: label(i), fix: nil, skip: "nothing to change") }
        return BulkStep(label: label(i), fix: f)
    }
}

public enum BulkOutcome: Equatable, Sendable {
    case done(String), skipped(String), failed(String)
}

/// "3 done, 1 skipped, 1 failed" followed by one line per item.
public func bulkReport(_ rows: [(label: String, outcome: BulkOutcome)]) -> String {
    var done = 0, skipped = 0, failed = 0
    let lines = rows.map { r -> String in
        switch r.outcome {
        case .done(let m): done += 1; return "✓ \(r.label)" + (m.isEmpty ? "" : ": \(m)")
        case .skipped(let m): skipped += 1; return "– \(r.label): skipped (\(m))"
        case .failed(let m): failed += 1; return "✗ \(r.label): failed: \(m)"
        }
    }
    return (["\(done) done, \(skipped) skipped, \(failed) failed", ""] + lines).joined(separator: "\n")
}

// MARK: Skills

/// A skill is its whole folder; other components are one file.
public func trashURL(_ c: Component) -> URL { c.kind == .skill && c.file.lastPathComponent == "SKILL.md" ? c.file.deletingLastPathComponent() : c.file }

/// Plugin skills follow their plugin, and other agents' skills are not ours to change.
public func skillBlock(_ c: Component) -> String? {
    c.ownsFile ? nil : c.scope == .external ? "belong to another agent" : "are plugin skills (manage them in Plugins)"
}

public func skillStatePlan(_ skills: [Component], to target: SkillState) -> [BulkStep] {
    bulkPlan(skills, label: { "/" + $0.name }, skip: { $0.state == target ? "already \(target.rawValue)" : nil }, fix: { $0.fix(to: target) })
}

public func skillUninstallPlan(_ skills: [Component]) -> [BulkStep] {
    bulkPlan(skills, label: { "/" + $0.name }, fix: { .trash([trashURL($0)]) })
}

// MARK: Clean-up review

/// The fix behind one finding's action, resolved against the current components.
public func cleanupFix(_ a: CleanupFinding.Action, components: [Component], plugins: [Plugin] = []) -> Fix? {
    let comp = { (id: String) in components.first { $0.id == id } }
    switch a {
    case .makeCallOnly(let id): return comp(id)?.fix(to: .onDemand)
    case .turnOff(let id): return comp(id)?.fix(to: .off)
    case .uninstall(let id): return comp(id).map { .trash([trashURL($0)]) }
    case .keepOne(_, let remove):
        let urls = remove.compactMap(comp).map(trashURL)
        return urls.isEmpty ? nil : .trash(urls)
    case .uninstallPlugin(let id): return plugins.first { $0.id == id }?.cli("uninstall") ?? .cli(args: ["plugin", "uninstall", id], dryRun: nil, cwd: nil)
    }
}

public func cleanupPlan(_ findings: [CleanupFinding], components: [Component], plugins: [Plugin] = []) -> [BulkStep] {
    bulkPlan(findings, label: { "\($0.kind.rawValue): \($0.title)" },
             skip: { $0.action == nil ? "no automatic fix" : nil },
             fix: { $0.action.flatMap { cleanupFix($0, components: components, plugins: plugins) } })
}

/// One CSV cell, quoted; a leading formula trigger gets a `'` so spreadsheets read it as text.
public func csvCell(_ s: String) -> String {
    let safe = s.first.map { "=+-@\t\r".contains($0) } == true ? "'" + s : s
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// POSIX single-quoting: `'` becomes `'\''`.
public func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// `cd <project> && claude --resume <id>`, or nil when the id isn't a UUID. A path under home keeps `"$HOME"` outside the quotes so it expands.
public func resumeCommand(project: String, id: String, home: String = NSHomeDirectory()) -> String? {
    guard UUID(uuidString: id) != nil else { return nil }
    let dir = project == home ? "\"$HOME\""
        : project.hasPrefix(home + "/") ? "\"$HOME\"/" + shellQuote(String(project.dropFirst(home.count + 1)))
        : shellQuote(project)
    return "cd \(dir) && claude --resume \(id)"
}
