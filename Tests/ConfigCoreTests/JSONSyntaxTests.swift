import XCTest
@testable import ConfigCore

final class JSONSyntaxTests: XCTestCase {
    func testTokensAndRoundTrip() {
        let src = "{\n  \"a\": \"x \\\" y\",\n  \"n\": -1.5e3,\n  \"b\": [true, false, null]\n}"
        let runs = JSONSyntax.runs(src)
        XCTAssertEqual(runs.map(\.text).joined(), src, "every character is kept")
        let tokens = Dictionary(runs.map { ($0.text, $0.token) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tokens["\"a\""], .key)
        XCTAssertEqual(tokens["\"x \\\" y\""], .string, "escaped quote stays inside the string")
        XCTAssertEqual(tokens["-1.5e3"], .number)
        XCTAssertEqual(tokens["true"], .bool)
        XCTAssertEqual(tokens["null"], .null)
    }

    func testUnterminatedStringDoesNotCrash() {
        XCTAssertEqual(JSONSyntax.runs("\"abc").map(\.text).joined(), "\"abc")
        XCTAssertEqual(JSONSyntax.runs("\"a\\").map(\.text).joined(), "\"a\\")
    }
}
