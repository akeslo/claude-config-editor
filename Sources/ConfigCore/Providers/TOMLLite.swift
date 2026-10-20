import Foundation

/// shortcut: display only, upgrade with a TOML lib if structured edits are needed (open question 1).
/// Table name ("" = root) → key → value; basic and `"""` strings unquoted (no escapes), everything else raw text.
public enum TOMLLite {
    public static func parse(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:], table = ""
        var lines = text.components(separatedBy: "\n")[...]
        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"\"\"") {
                var body = String(value.dropFirst(3)), parts: [String] = []
                while !body.contains("\"\"\""), let next = lines.popFirst() { parts.append(body); body = next }
                parts.append(String(body[..<(body.range(of: "\"\"\"")?.lowerBound ?? body.endIndex)]))
                if parts.first == "" { parts.removeFirst() }  // TOML drops the newline right after the opener
                value = parts.joined(separator: "\n")
            } else if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            out[table, default: [:]][key] = value
        }
        return out
    }
}
