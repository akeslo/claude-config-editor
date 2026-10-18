import Foundation

public struct AdviceRule: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case official, community }
    public let id: String
    public let area: AppSection
    public let kind: Kind
    public let text: String
    public let why: String?
    public let source: URL
    public let check: String?
    public let retired: Bool?

    /// JSON area keys -> sections; anything else is invalid.
    static let areaKeys: [String: AppSection] = [
        "skills": .mySkills, "instructions": .instructions, "mcp": .mcp, "hooks": .hooks,
        "permissions": .permissions, "settings": .settings, "plugins": .plugins,
    ]

    enum CodingKeys: String, CodingKey { case id, area, kind, text, why, source, check, retired }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let key = try c.decode(String.self, forKey: .area)
        guard let a = Self.areaKeys[key] else {
            throw DecodingError.dataCorruptedError(forKey: .area, in: c, debugDescription: "unknown area \(key)")
        }
        area = a
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        source = try c.decode(URL.self, forKey: .source)
        check = try c.decodeIfPresent(String.self, forKey: .check)
        retired = try c.decodeIfPresent(Bool.self, forKey: .retired)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Self.areaKeys.first { $0.value == area }?.key, forKey: .area)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(why, forKey: .why)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(check, forKey: .check)
        try c.encodeIfPresent(retired, forKey: .retired)
    }

    /// Checks this rule against the scanned setup; nil when it has no (known) `check`.
    public func measure(_ s: Snapshot) -> (met: Bool, note: String)? {
        switch check {
        case "claudemd-lines":
            let longest = s.instructions.filter { $0.kind == .claudeMD }.map(\.lines).max() ?? 0
            return (longest <= 200, "yours: \(longest)")
        case "skillmd-lines":
            let longest = s.components.filter { $0.kind == .skill }.map(\.lineCount).max() ?? 0
            return (longest <= 500, "yours: \(longest)")
        case "no-env-secrets":
            let n = Checks.settingsChecks(s).filter { $0.title == "Secret in settings env" }.count
            return (n == 0, n == 0 ? "none found" : "found in \(n) settings file\(n == 1 ? "" : "s")")
        case "no-broad-permissions":
            let n = Checks.permissionChecks(s).filter { $0.title == "Very broad permission rule" }.count
            return (n == 0, n == 0 ? "none found" : "\(n) broad rule\(n == 1 ? "" : "s")")
        default: return nil
        }
    }
}

public struct Advice: Sendable {
    public let rules: [AdviceRule]

    public init(rules: [AdviceRule]) { self.rules = rules }

    public func rule(_ id: String) -> AdviceRule? { rules.first { $0.id == id } }
    public func rules(for area: AppSection) -> [AdviceRule] { rules.filter { $0.area == area } }

    /// Keeps each valid, non-retired rule on its own so one bad rule doesn't sink the rest; nil if none survive.
    public static func decode(_ data: Data) -> Advice? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let items = root["rules"] as? [Any] else { return nil }
        var seen = Set<String>()
        let rules: [AdviceRule] = items.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let d = try? JSONSerialization.data(withJSONObject: item),
                  let r = try? JSONDecoder().decode(AdviceRule.self, from: d),
                  r.retired != true, !r.id.isEmpty, !r.text.isEmpty,
                  ["http", "https"].contains(r.source.scheme), r.source.host != nil,
                  seen.insert(r.id).inserted else { return nil }  // keep first of duplicate ids
            return r
        }
        return rules.isEmpty ? nil : Advice(rules: rules)
    }

    /// First source that decodes, in order fetched, cached, bundled; else empty.
    public static func pick(fetched: Data?, cached: Data?, bundled: Data?) -> Advice {
        for d in [fetched, cached, bundled] { if let d, let a = decode(d) { return a } }
        return Advice(rules: [])
    }
}
