import Testing
@testable import ConfigCore

struct AnswerBlocksTests {
    @Test func splitsProseAndBlocksWithLanguage() {
        let s = AnswerBlocks.segments("Here:\n```markdown\nline 1\nline 2\n```\nDone.")
        #expect(s == [.text("Here:"), .code(language: "markdown", body: "line 1\nline 2"), .text("Done.")])
    }

    @Test func longerFenceHoldsInnerBackticks() {
        let s = AnswerBlocks.segments("````\nouter\n```swift\nlet x = 1\n```\n````")
        #expect(s == [.code(language: "", body: "outer\n```swift\nlet x = 1\n```")])
    }

    @Test func unterminatedFenceRunsToEnd() {
        let s = AnswerBlocks.segments("Prompt:\n```\n5. superpowers:test-driven-development – Add a test first: a fresh profile with")
        #expect(s == [.text("Prompt:"), .code(language: "", body: "5. superpowers:test-driven-development – Add a test first: a fresh profile with")])
    }

}
