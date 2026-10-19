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

    public static func codeBlocks(_ text: String) -> [String] {
        segments(text).compactMap { if case .code(_, let b) = $0 { b } else { nil } }
    }

    /// "give me a prompt", "write a prompt for…", "draft prompt": the word prompt plus a verb asking for one.
    public static func asksForPrompt(_ question: String) -> Bool {
        let words = Set(question.lowercased().split { !$0.isLetter }.map(String.init))
        let verbs: Set = ["give", "write", "make", "draft", "create", "generate", "build", "craft", "compose", "need", "want", "suggest", "produce", "prepare"]
        return (words.contains("prompt") || words.contains("prompts")) && !words.isDisjoint(with: verbs)
    }

    /// The block to put on the clipboard, or nil. Exactly one block, or exactly one whose language tag or the line
    /// just above it calls it the prompt; several unmarked blocks are left to the per-block Copy buttons.
    public static func autoCopyText(question: String, answer: String) -> String? {
        guard asksForPrompt(question) else { return nil }
        let segs = segments(answer)
        var blocks: [(marked: Bool, body: String)] = []
        for (i, s) in segs.enumerated() {
            guard case .code(let lang, let body) = s, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var lead = ""
            if i > 0, case .text(let t) = segs[i - 1] { lead = t.split(separator: "\n").last.map(String.init) ?? "" }
            blocks.append((lang.lowercased() == "prompt" || lead.lowercased().contains("prompt"), body))
        }
        if blocks.count == 1 { return blocks[0].body }
        let marked = blocks.filter(\.marked)
        return marked.count == 1 ? marked[0].body : nil
    }
}
