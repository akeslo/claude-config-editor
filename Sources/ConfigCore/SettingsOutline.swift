import Foundation

/// Turns a nested settings value (hooks, permissions, plugins…) into a scannable outline
/// instead of a raw JSON wall. Pure/Foundation-only so it is unit-tested.
public enum SettingsOutline {
    public struct Section: Equatable, Identifiable {
        public let title: String
        public let rows: [String]
        public var id: String { title }
        public init(title: String, rows: [String]) { self.title = title; self.rows = rows }
    }

    /// Sections for a key worth structuring, or nil to fall back to raw JSON.
    public static func sections(key: String, value: Any?) -> [Section]? {
        switch key {
        case "hooks": return hooks(value)
        case "permissions": return permissions(value)
        case "enabledPlugins", "pluginConfigs", "extraKnownMarketplaces": return plugins(value)
        default: return generic(value)
        }
    }

    /// One-line summary for a table cell, e.g. "4 events · 9 hooks". Nil when nothing to summarise.
    public static func summary(key: String, value: Any?) -> String? {
        guard let secs = sections(key: key, value: value), !secs.isEmpty else { return nil }
        let items = secs.reduce(0) { $0 + $1.rows.count }
        let unit = key == "hooks" ? "hook" : key == "permissions" ? "rule" : "item"
        return "\(secs.count) \(noun(secs.count, "group")) · \(items) \(noun(items, unit))"
    }

    // MARK: - Shapers

    private static func hooks(_ value: Any?) -> [Section]? {
        guard let events = value as? [String: Any] else { return nil }
        return events.keys.sorted().map { event in
            var rows: [String] = []
            for entry in (events[event] as? [Any] ?? []) {
                guard let obj = entry as? [String: Any] else { continue }
                let matcher = (obj["matcher"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // Entry is either a matcher group {matcher, hooks:[...]} or a hook {command,...} directly.
                let inner = (obj["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [obj]
                for h in inner { rows.append(hookRow(matcher: matcher, h)) }
            }
            return Section(title: "\(event) (\(rows.count))", rows: rows)
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

    private static func permissions(_ value: Any?) -> [Section]? {
        guard let perms = value as? [String: Any] else { return nil }
        let order = ["allow", "ask", "deny", "additionalDirectories"]
        let keys = order.filter { perms[$0] != nil } + perms.keys.filter { !order.contains($0) }.sorted()
        return keys.map { k in
            let rows = (perms[k] as? [Any])?.map { "\($0)" } ?? ["\(perms[k]!)"]
            return Section(title: "\(k) (\(rows.count))", rows: rows)
        }
    }

    private static func plugins(_ value: Any?) -> [Section]? {
        if let dict = value as? [String: Any] {
            let rows = dict.keys.sorted().map { key -> String in
                if let on = dict[key] as? Bool { return "\(key) — \(on ? "enabled" : "disabled")" }
                return key
            }
            return [Section(title: "entries (\(rows.count))", rows: rows)]
        }
        if let arr = value as? [Any] { return [Section(title: "entries (\(arr.count))", rows: arr.map { "\($0)" })] }
        return nil
    }

    /// Fallback for any other object/array: one row per key/element; nil for scalars.
    private static func generic(_ value: Any?) -> [Section]? {
        if let dict = value as? [String: Any] {
            return [Section(title: "keys (\(dict.count))", rows: dict.keys.sorted().map { "\($0): \(scalar(dict[$0]!))" })]
        }
        if let arr = value as? [Any] { return [Section(title: "items (\(arr.count))", rows: arr.map { scalar($0) })] }
        return nil
    }

    private static func scalar(_ v: Any) -> String {
        if let d = v as? [String: Any] { return "{\(d.count) \(noun(d.count, "key"))}" }
        if let a = v as? [Any] { return "[\(a.count) \(noun(a.count, "item"))]" }
        if let s = v as? String { return s }
        return "\(v)"
    }

    private static func noun(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }
}
