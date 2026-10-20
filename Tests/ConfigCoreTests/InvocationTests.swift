import Foundation
import Testing
@testable import ConfigCore

@Test func invocationStrings() {
    let tmp = URL(filePath: NSTemporaryDirectory())
    #expect(Scanner.component(.skill, tmp.appending(path: "x/SKILL.md"), "copy-that-sells", .plugin, "copy-that-sells@m", "copy-that-sells:").invocation == "/copy-that-sells:copy-that-sells")
    #expect(Scanner.component(.skill, tmp.appending(path: "y/SKILL.md"), "enhance", .user, nil, "").invocation == "/enhance")
    #expect(Scanner.component(.command, tmp.appending(path: "commit.md"), "commit", .plugin, "cc@m", "commit-commands:").invocation == "/commit-commands:commit")
}
