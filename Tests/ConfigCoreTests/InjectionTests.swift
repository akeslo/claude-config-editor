import Testing
@testable import ConfigCore

@Suite struct InjectionTests {
    @Test func csvNeutralisesFormulas() {
        #expect(csvCell("=SUM(A1)") == "\"'=SUM(A1)\"")
        #expect(csvCell("@x") == "\"'@x\"")
        #expect(csvCell("\tx") == "\"'\tx\"")
        #expect(csvCell("a\"b") == "\"a\"\"b\"")
        #expect(csvCell("plain") == "\"plain\"")
    }

    @Test func resumeQuotesPathAndRejectsBadIds() {
        let id = "123e4567-e89b-12d3-a456-426614174000"
        #expect(resumeCommand(project: "/p", id: "x; rm -rf ~") == nil)
        #expect(resumeCommand(project: "/h/a'b $(x)", id: id, home: "/h") == "cd \"$HOME\"/'a'\\''b $(x)' && claude --resume \(id)")
        #expect(resumeCommand(project: "/opt/x", id: id, home: "/h") == "cd '/opt/x' && claude --resume \(id)")
        #expect(resumeCommand(project: "/h", id: id, home: "/h") == "cd \"$HOME\" && claude --resume \(id)")
    }
}
