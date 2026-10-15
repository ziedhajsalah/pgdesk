import XCTest
@testable import PGDeskCore

/// Cell editing and query cancel against local Postgres, using temp tables only.
final class EditingAndCancelTests: XCTestCase {
    var session: DatabaseSession!

    override func setUp() async throws {
        session = try await DatabaseSession.connect(ConnectionConfig(), password: nil)
    }

    override func tearDown() async throws {
        await session?.close()
    }

    private func tempTable(_ name: String) async throws -> (Relation, [ColumnInfo]) {
        let tempSchema = try await session.run("select nspname from pg_namespace where oid = pg_my_temp_schema()")
        let schema = try XCTUnwrap(tempSchema.rows.first?.first ?? nil)
        let relation = Relation(schema: schema, name: name, kind: .table)
        return (relation, try await session.columns(of: relation))
    }

    func testEditabilityRules() async throws {
        let pgClass = Relation(schema: "pg_catalog", name: "pg_class", kind: .table)
        let catalogColumns = try await session.columns(of: pgClass)
        XCTAssertTrue(catalogColumns.contains(where: \.isPrimaryKey), "pg_class has a primary key since PG14")
        XCTAssertFalse(RowEditing.isEditable(pgClass, columns: catalogColumns))

        let key = ColumnInfo(name: "id", type: "integer", nullable: false, defaultValue: "", isPrimaryKey: true)
        let plain = ColumnInfo(name: "v", type: "text", nullable: true, defaultValue: "", isPrimaryKey: false)
        XCTAssertTrue(RowEditing.isEditable(Relation(schema: "public", name: "t", kind: .table), columns: [key, plain]))
        XCTAssertTrue(RowEditing.isEditable(Relation(schema: "public", name: "t", kind: .partitioned), columns: [key, plain]))
        XCTAssertFalse(RowEditing.isEditable(Relation(schema: "public", name: "t", kind: .table), columns: [plain]))
        XCTAssertFalse(RowEditing.isEditable(Relation(schema: "public", name: "v", kind: .view), columns: [key, plain]))
        XCTAssertFalse(RowEditing.isEditable(Relation(schema: "public", name: "m", kind: .materializedView), columns: [key, plain]))
        XCTAssertFalse(RowEditing.isEditable(Relation(schema: "information_schema", name: "t", kind: .table), columns: [key, plain]))
    }

    func testUpdateStatementShape() throws {
        let relation = Relation(schema: "s", name: "we\"ird", kind: .table)
        let columns = [
            ColumnInfo(name: "a", type: "integer", nullable: false, defaultValue: "", isPrimaryKey: true),
            ColumnInfo(name: "na\"me", type: "text", nullable: true, defaultValue: "", isPrimaryKey: false),
            ColumnInfo(name: "b", type: "uuid", nullable: false, defaultValue: "", isPrimaryKey: true),
        ]
        let update = try RowEditing.update(relation, columns: columns, row: ["1", "x", "u"], column: "na\"me", value: nil)
        XCTAssertEqual(update.sql, """
            update "s"."we""ird" as _t set "na""me" = $1 where _t."a" = $2 and _t."b" = $3 \
            returning _t."a"::text, _t."na""me"::text, _t."b"::text
            """)
        XCTAssertEqual(update.binds, [nil, "1", "u"])

        XCTAssertThrowsError(try RowEditing.update(relation, columns: columns, row: [nil, "x", "u"], column: "a", value: "2"))
        XCTAssertThrowsError(try RowEditing.update(relation, columns: columns, row: ["1"], column: "a", value: "2"))
        XCTAssertThrowsError(try RowEditing.update(relation, columns: columns, row: ["1", "x", "u"], column: "nope", value: "2"))
    }

    func testUpdatesCellsOfManyTypes() async throws {
        _ = try await session.run("""
            create temp table "ed""it" (
                id int, k uuid, flag bool, amount numeric(10,2), at timestamptz, doc jsonb, note text, tags text[],
                primary key (id, k)
            )
            """)
        _ = try await session.run("""
            insert into "ed""it" values
                (1, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', false, 1.50, '2024-01-02 03:04:05+00', '{"a": 1}', 'line1', '{x}'),
                (1, 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', true, 9.99, null, null, 'other', null)
            """)
        let (relation, columns) = try await tempTable("ed\"it")
        XCTAssertTrue(RowEditing.isEditable(relation, columns: columns))

        var page = try await session.page(of: relation, columns: columns, request: PageRequest())
        var row = try XCTUnwrap(page.rows.first)
        let index = { (name: String) in columns.firstIndex { $0.name == name }! }

        let edits: [(String, String?, String?)] = [
            ("flag", "true", "true"),
            ("amount", "12.345", "12.35"),
            ("at", row[index("at")]!, row[index("at")]), // round-trips the page's own text
            ("doc", "{\"b\": [1, 2]}", "{\"b\": [1, 2]}"),
            ("note", "two\nlines, \"quoted\" ✓", "two\nlines, \"quoted\" ✓"),
            ("note", "", ""),
            ("note", nil, nil),
            ("tags", "{a,\"b c\"}", "{a,\"b c\"}"),
        ]
        for (column, value, expected) in edits {
            row = try await session.updateCell(of: relation, columns: columns, row: row, column: column, value: value)
            XCTAssertEqual(row[index(column)], expected, column)
        }

        // Editing a key column works too, and the returned row carries the new key.
        row = try await session.updateCell(of: relation, columns: columns, row: row, column: "id", value: "7")
        XCTAssertEqual(row[index("id")], "7")

        page = try await session.page(of: relation, columns: columns, request: PageRequest())
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows.last, row, "the stored row matches the returned row")
        XCTAssertEqual(page.rows.first?[index("note")], "other", "the other row with the same id is untouched")

        // A bad value is reported as the server's error and changes nothing.
        do {
            _ = try await session.updateCell(of: relation, columns: columns, row: row, column: "amount", value: "abc")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid input syntax for type numeric"), error.localizedDescription)
        }

        // A row that no longer exists is reported, not silently ignored.
        var stale = row
        stale[index("id")] = "999"
        do {
            _ = try await session.updateCell(of: relation, columns: columns, row: stale, column: "note", value: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("No row was updated"), error.localizedDescription)
        }
    }

    func testCancelStopsRunningQuery() async throws {
        let session = self.session!
        let started = ContinuousClock.now
        let query = Task { try await session.run("select pg_sleep(30)") }
        // Wait until the server is actually running the statement, so the cancel can't arrive early.
        let observer = try await DatabaseSession.connect(ConnectionConfig(), password: nil)
        defer { Task { await observer.close() } }
        for _ in 0..<100 {
            let state = try await observer.run(
                "select count(*) from pg_stat_activity where pid = \(session.backendPID) and state = 'active'"
            )
            if state.rows.first?.first == "1" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let cancelled = try await session.cancelRunningQuery()
        XCTAssertTrue(cancelled)
        do {
            _ = try await query.value
            XCTFail("expected the query to be cancelled")
        } catch let error as PGDeskError {
            XCTAssertTrue(error.isQueryCancelled, error.message)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        // The connection is still usable afterwards.
        let after = try await session.run("select 1 as one")
        XCTAssertEqual(after.rows.first?.first, "1")
    }
}
