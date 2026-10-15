import XCTest
@testable import PGDeskCore

final class SQLHighlighterTests: XCTestCase {
    /// Returns (kind, text) pairs so expectations read like the SQL itself.
    private func lex(_ sql: String) -> [(SQLToken.Kind, String)] {
        let ns = sql as NSString
        return SQLHighlighter.tokens(in: sql).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func assertLex(_ sql: String, _ expected: [(SQLToken.Kind, String)], file: StaticString = #filePath, line: UInt = #line) {
        let actual = lex(sql)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), "\(actual)", file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    func testKeywordsNumbersStringsComments() {
        assertLex("SELECT a, 1.5e10, .5, 42 FROM t -- tail\nwhere x = 'it''s'", [
            (.keyword, "SELECT"), (.number, "1.5e10"), (.number, ".5"), (.number, "42"), (.keyword, "FROM"),
            (.comment, "-- tail"), (.keyword, "where"), (.string, "'it''s'"),
        ])
    }

    func testIdentifiersAreNotKeywordsOrNumbers() {
        assertLex("select col1, selected, \"select\", from_x, 1abc, t.from from t2", [
            (.keyword, "select"), (.keyword, "from"), (.keyword, "from"),
        ])
    }

    func testNestedBlockCommentsAndUnterminated() {
        assertLex("/* a /* b */ still */ select /* open", [
            (.comment, "/* a /* b */ still */"), (.keyword, "select"), (.comment, "/* open"),
        ])
    }

    func testEscapeAndDollarQuotedStrings() {
        assertLex(#"select E'a\'b', e'x', $$it's $1$$, $fn$ select 'x' $fn$, $1, a$b"#, [
            (.keyword, "select"), (.string, #"E'a\'b'"#), (.string, "e'x'"), (.string, "$$it's $1$$"),
            (.string, "$fn$ select 'x' $fn$"),
        ])
    }

    func testRangesAreUTF16() {
        let sql = "select '😀' from t"
        let tokens = SQLHighlighter.tokens(in: sql)
        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 0, length: 6), NSRange(location: 7, length: 4), NSRange(location: 12, length: 4)])
        XCTAssertEqual((sql as NSString).substring(with: tokens[2].range), "from")
    }

    /// The dirty range must cover every position whose colour changed: recolouring only that range
    /// has to give the same result as recolouring everything.
    func testDirtyRangeCoversEveryChange() {
        let cases: [(String, NSRange, String)] = [
            ("select a from t", NSRange(location: 8, length: 0), "x"),          // typing in a plain word
            ("select a from t", NSRange(location: 7, length: 0), "'"),          // opening a string to the end
            ("select 'a' from t", NSRange(location: 7, length: 1), ""),         // deleting a quote
            ("sel a from t", NSRange(location: 3, length: 0), "ect"),           // finishing a keyword
            ("select 1 /* x */ from t", NSRange(location: 9, length: 2), ""),   // breaking a comment
            ("a\nb -- c\nselect", NSRange(location: 0, length: 15), "from"),    // replacing everything
        ]
        for (before, edited, inserted) in cases {
            let after = (before as NSString).replacingCharacters(in: edited, with: inserted)
            let newEdited = NSRange(location: edited.location, length: (inserted as NSString).length)
            let delta = newEdited.length - edited.length
            let old = SQLHighlighter.tokens(in: before)
            let new = SQLHighlighter.tokens(in: after)
            let dirty = SQLHighlighter.dirtyRange(old: old, new: new, edited: newEdited, changeInLength: delta)

            // Colours per UTF-16 position: old colours moved like NSTextStorage moves attributes.
            func colours(_ tokens: [SQLToken], count: Int) -> [SQLToken.Kind?] {
                var out = [SQLToken.Kind?](repeating: nil, count: count)
                for t in tokens { for k in t.location..<min(t.end, count) { out[k] = t.kind } }
                return out
            }
            let oldColours = colours(old, count: (before as NSString).length)
            var moved = Array(oldColours[0..<edited.location])
            moved += [SQLToken.Kind?](repeating: .some(.comment), count: newEdited.length) // typing attributes: arbitrary
            moved += oldColours[NSMaxRange(edited)...]
            let expected = colours(new, count: (after as NSString).length)
            for k in 0..<expected.count where moved[k] != expected[k] {
                XCTAssertTrue(NSLocationInRange(k, dirty), "\(before) → \(after): position \(k) changed but \(dirty) misses it")
            }
            XCTAssertLessThanOrEqual(NSMaxRange(dirty), (after as NSString).length)
        }
    }

    func testDirtyRangeStaysSmallForLocalEdits() {
        let body = String(repeating: "select a, 'b', 3 from t where x = 1; -- c\n", count: 2000)
        let before = body + body
        let at = (body as NSString).length + 7
        let after = (before as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "z")
        let dirty = SQLHighlighter.dirtyRange(
            old: SQLHighlighter.tokens(in: before), new: SQLHighlighter.tokens(in: after),
            edited: NSRange(location: at, length: 1), changeInLength: 1
        )
        XCTAssertLessThan(dirty.length, 20, "\(dirty)")
    }

    func testCSV() {
        let csv = CSV.encode(columns: ["id", "na,me"], rows: [
            ["1", "plain"], ["2", "say \"hi\""], ["3", "two\nlines"], ["4", nil], ["5", ""],
        ])
        XCTAssertEqual(csv, """
            id,"na,me"
            1,plain
            2,"say ""hi\"\"\"
            3,"two
            lines"
            4,
            5,""

            """)
    }
}
