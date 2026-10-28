import Foundation

/// Turns a nested settings value (hooks, permissions, plugins, or any object/array) into a
/// scannable collapsible tree instead of a raw JSON wall. Pure/Foundation-only so it is unit-tested.
public enum SettingsOutline {
    public indirect enum Node: Equatable {
        case leaf(label: String?, value: String, kind: Kind = .text)          // a scalar, optionally labelled by its key
        case branch(title: String, children: [Node], kind: Kind = .text)     // an object/array, collapsible
    }

    /// The JSON type behind a node, so the view can colour it. Curated rows (hooks, rules) stay `.text`.
    public enum Kind: Equatable, Sendable { case text, string, number, bool, null, object, array }

    /// Top-level tree for a value, or nil when the value is a scalar (render it plainly).
    /// Known keys get curated titles; everything else falls back to a generic tree, so new/unknown
    /// keys (e.g. autoMode) are structured automatically with no per-key code.
    public static func tree(key: String, value: Any?) -> [Node]? {
        switch key {
        case "hooks": return hooks(value)
        case "permissions": return permissions(value)
        case "enabledPlugins", "pluginConfigs", "extraKnownMarketplaces": return plugins(value)
        default: return generic(value)
        }
    }

    /// One-line summary for a table cell, e.g. "4 groups · 9 hooks". Nil when nothing to summarise.
    public static func summary(key: String, value: Any?) -> String? {
        guard let nodes = tree(key: key, value: value), !nodes.isEmpty else { return nil }
        let groups = nodes.filter { if case .branch = $0 { return true } else { return false } }.count
        let leaves = nodes.reduce(0) { $0 + leafCount($1) }
        let unit = key == "hooks" ? "hook" : key == "permissions" ? "rule" : "item"
        if groups == 0 { return "\(leaves) \(noun(leaves, unit))" }
        return "\(groups) \(noun(groups, "group")) · \(leaves) \(noun(leaves, unit))"
    }

    private static func leafCount(_ node: Node) -> Int {
        switch node {
        case .leaf: return 1
        case .branch(_, let kids, _): return kids.reduce(0) { $0 + leafCount($1) }
        }
    }

    // MARK: - Known shapers

    private static func hooks(_ value: Any?) -> [Node]? {
        guard let events = value as? [String: Any] else { return nil }
        return events.keys.sorted().map { event in
            var rows: [Node] = []
            for entry in (events[event] as? [Any] ?? []) {
                guard let obj = entry as? [String: Any] else { continue }
                let matcher = (obj["matcher"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // Entry is either a matcher group {matcher, hooks:[...]} or a hook {command,...} directly.
                let inner = (obj["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [obj]
                for h in inner { rows.append(.leaf(label: nil, value: hookRow(matcher: matcher, h))) }
            }
            return .branch(title: "\(event) (\(rows.count))", children: rows)
        }
    }

    private static func hookRow(matcher: String?, _ h: [String: Any]) -> String {
        let cmd = (h["command"] as? String) ?? (h["type"] as? String) ?? "hook"
        var tail: [String] = []
        if let t = h["timeout"] { tail.append("\(t)s") }
        if (h["async"] as? Bool) == true { tail.append("async") }
        let prefix = matcher.map { "\($0) — " } ?? ""
        let suffix = tail.isEmpty ? "" : "  (\(tail.joined(separator: ", ")))"
        return prefix + cmd + suffix
    }

    private static func permissions(_ value: Any?) -> [Node]? {
        guard let perms = value as? [String: Any] else { return nil }
        let order = ["allow", "ask", "deny", "additionalDirectories"]
        let keys = order.filter { perms[$0] != nil } + perms.keys.filter { !order.contains($0) }.sorted()
        return keys.map { k in
            let rows = (perms[k] as? [Any])?.map { Node.leaf(label: nil, value: "\($0)") } ?? [.leaf(label: nil, value: "\(perms[k]!)")]
            return .branch(title: "\(k) (\(rows.count))", children: rows)
        }
    }

    private static func plugins(_ value: Any?) -> [Node]? {
        if let dict = value as? [String: Any] {
            let rows = dict.keys.sorted().map { key -> Node in
                if let on = dict[key] as? Bool { return .leaf(label: nil, value: "\(key) — \(on ? "enabled" : "disabled")") }
                return .leaf(label: nil, value: key)
            }
            return [.branch(title: "entries (\(rows.count))", children: rows)]
        }
        if let arr = value as? [Any] { return [.branch(title: "entries (\(arr.count))", children: arr.map { .leaf(label: nil, value: "\($0)") })] }
        return nil
    }

    // MARK: - Generic tree (default for any object/array)

    private static func generic(_ value: Any?) -> [Node]? {
        guard let v = value, isContainer(v) else { return nil }
        return childNodes(of: v)
    }

    private static func isContainer(_ v: Any) -> Bool { v is [String: Any] || v is [Any] }

    private static func childNodes(of v: Any) -> [Node] {
        if let d = v as? [String: Any] { return d.keys.sorted().map { node(label: $0, value: d[$0]!) } }
        if let a = v as? [Any] { return a.map { node(label: nil, value: $0) } }
        return []
    }

    private static func node(label: String?, value: Any) -> Node {
        if let d = value as? [String: Any] { return .branch(title: title(label, d.count, "key"), children: childNodes(of: value), kind: .object) }
        if let a = value as? [Any] { return .branch(title: title(label, a.count, "item"), children: childNodes(of: value), kind: .array) }
        return .leaf(label: label, value: scalarString(value), kind: kind(of: value))
    }

    private static func title(_ label: String?, _ count: Int, _ word: String) -> String {
        let n = "\(count) \(noun(count, word))"
        return label.map { "\($0) (\(n))" } ?? "(\(n))"
    }

    static func kind(of v: Any) -> Kind {
        if v is NSNull { return .null }
        if v is String { return .string }
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool : .number }
        return .text
    }

    private static func scalarString(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let s = v as? String { return s }
        return "\(v)"
    }

    private static func noun(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }
}
