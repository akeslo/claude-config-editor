import Foundation

/// Splits a Claude answer into prose and fenced code blocks, and decides when to auto-copy a requested prompt.
public enum AnswerBlocks {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case code(language: String, body: String)
    }

    /// CommonMark-style fences: an opening run of 3+ backticks (or tildes) closes only on a run at least as long,
    /// so a ```` block can hold ``` lines. An unterminated fence (a streamed or cut-off answer) runs to the end.
    public static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = [], prose: [Substring] = [], code: [Substring] = []
        var fence: (char: Character, count: Int, lang: String)?
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            let ch = trimmed.first
            let run = (ch == "`" || ch == "~") ? trimmed.prefix { $0 == ch }.count : 0
            if let f = fence {
                if ch == f.char, run >= f.count, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                    out.append(.code(language: f.lang, body: code.joined(separator: "\n"))); code = []; fence = nil
                } else { code.append(line) }
            } else if run >= 3, let ch {
                flushProse()
                fence = (ch, run, trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "")
            } else { prose.append(line) }
        }
        if let f = fence { out.append(.code(language: f.lang, body: code.joined(separator: "\n"))) }
        flushProse()
        return out
    }

    /// Prose as display text: inline markdown (**bold**, `code`, links) rendered, "- "/"* " bullets as "•", "# " headings bold.
    public static func rich(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = AttributedString()
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            let indent = line.prefix { $0 == " " }
            let body = line.dropFirst(indent.count)
            if body.hasPrefix("- ") || body.hasPrefix("* ") { line = indent + "• " + body.dropFirst(2) }
            else if let h = body.firstIndex(where: { $0 != "#" }), h != body.startIndex, body[h] == " " { line = "**" + body[h...].trimmingCharacters(in: .whitespaces) + "**" }
            if i > 0 { out += AttributedString("\n") }
            out += (try? AttributedString(markdown: line, options: opts)) ?? AttributedString(line)
        }
        return out
    }
}
