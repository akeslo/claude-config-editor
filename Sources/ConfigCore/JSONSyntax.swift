import Foundation

/// Splits JSON text into coloured runs for read-only display. A lenient scanner, not a parser:
/// invalid text still comes back whole (unknown characters are `.punctuation`), so nothing is dropped.
public enum JSONSyntax {
    public enum Token: Equatable, Sendable { case key, string, number, bool, null, punctuation }

    public struct Run: Equatable, Sendable {
        public let text: String
        public let token: Token
    }

    public static func runs(_ s: String) -> [Run] {
        var out: [Run] = []
        let c = Array(s)
        var i = 0
        func emit(_ from: Int, _ to: Int, _ t: Token) {
            let text = String(c[from..<to])
            if let last = out.last, last.token == t { out[out.count - 1] = Run(text: last.text + text, token: t) }
            else { out.append(Run(text: text, token: t)) }
        }
        while i < c.count {
            let start = i
            if c[i] == "\"" {
                i += 1
                while i < c.count, c[i] != "\"" { i += c[i] == "\\" ? 2 : 1 }
                i = min(i + 1, c.count)
                // A string followed (past whitespace) by ':' is an object key.
                var j = i
                while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
                emit(start, i, j < c.count && c[j] == ":" ? .key : .string)
            } else if c[i] == "-" || c[i].isNumber {
                i += 1
                while i < c.count, c[i].isNumber || "+-.eE".contains(c[i]) { i += 1 }
                emit(start, i, .number)
            } else if let word = ["true", "false", "null"].first(where: { hasWord($0, c, i) }) {
                i += word.count
                emit(start, i, word == "null" ? .null : .bool)
            } else {
                i += 1
                emit(start, i, .punctuation)
            }
        }
        return out
    }

    private static func hasWord(_ w: String, _ c: [Character], _ i: Int) -> Bool {
        let w = Array(w)
        return i + w.count <= c.count && Array(c[i..<i + w.count]) == w
    }
}
