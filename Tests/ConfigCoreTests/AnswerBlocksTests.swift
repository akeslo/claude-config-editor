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

    @Test func detectsPromptRequests() {
        #expect(AnswerBlocks.asksForPrompt("Give me a prompt to set up TDD"))
        #expect(AnswerBlocks.asksForPrompt("can you write a Prompt for this?"))
        #expect(!AnswerBlocks.asksForPrompt("What does the prompt hook do?"))
        #expect(!AnswerBlocks.asksForPrompt("Write a summary of my skills"))
    }

    @Test func autoCopyDecision() {
        let q = "write a prompt for this"
        #expect(AnswerBlocks.autoCopyText(question: q, answer: "Use:\n```\nDo X.\n```") == "Do X.")
        #expect(AnswerBlocks.autoCopyText(question: "what is this?", answer: "```\nDo X.\n```") == nil)
        #expect(AnswerBlocks.autoCopyText(question: q, answer: "```\na\n```\n```\nb\n```") == nil)
        #expect(AnswerBlocks.autoCopyText(question: q, answer: "Setup:\n```sh\nls\n```\nThe prompt:\n```\nDo Y.\n```") == "Do Y.")
        #expect(AnswerBlocks.autoCopyText(question: q, answer: "No blocks here.") == nil)
    }
}
