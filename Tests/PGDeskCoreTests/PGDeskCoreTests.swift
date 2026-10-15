import XCTest
@testable import PGDeskCore

/// Runs against the local Homebrew Postgres (current user, no password, `postgres` database).
/// Uses temp tables only, so nothing persists.
final class PGDeskCoreTests: XCTestCase {
    var session: DatabaseSession!

    override func setUp() async throws {
        session = try await DatabaseSession.connect(ConnectionConfig(), password: nil)
    }

    override func tearDown() async throws {
        await session?.close()
    }

    func testFormatsCommonTypes() async throws {
        let result = try await session.run("""
            select true as b, 42::int2 as i2, 42::int4 as i4, 9000000000::int8 as i8, 'pg_class'::regclass::oid as o,
                   1.5::float4 as f4, 2.25::float8 as f8, 123.4500::numeric as n, 'hi'::text as t, 'v'::varchar as vc,
                   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid as u, '{"a": 1}'::jsonb as jb, '{"a":1}'::json as j,
                   '2024-01-02'::date as d, '2024-01-02 03:04:05.5+00'::timestamptz as ts, '\\x0102'::bytea as by,
                   array['x','y'] as ta, array[1,2]::int4[] as ia, null::text as nul, '1 day'::interval as iv,
                   '1 year 2 mons 3 days 04:05:06.5'::interval as iv2, '1.2.3.4'::inet as ip,
                   10::numeric(10,2) as n2, -0.000123::numeric as n3, 123456789012345678901234567890.5::numeric as n4,
                   'NaN'::numeric as n5, 0::numeric as n6,
                   'infinity'::interval as ivp, '-infinity'::interval as ivn, '-5 hours -3 minutes'::interval as ivneg,
                   'infinity'::timestamptz as tsp, '-infinity'::timestamp as tsn, 'infinity'::date as dp, '-infinity'::date as dn
            """)
        XCTAssertEqual(result.columns.count, 34)
        let row = Dictionary(uniqueKeysWithValues: zip(result.columns, result.rows[0]))
        XCTAssertEqual(row["b"], "true")
        XCTAssertEqual(row["i2"], "42")
        XCTAssertEqual(row["i4"], "42")
        XCTAssertEqual(row["i8"], "9000000000")
        XCTAssertEqual(row["o"], "1259")
        XCTAssertEqual(row["f4"], "1.5")
        XCTAssertEqual(row["f8"], "2.25")
        XCTAssertEqual(row["n"], "123.4500")
        XCTAssertEqual(row["n2"], "10.00")
        XCTAssertEqual(row["n3"], "-0.000123")
        XCTAssertEqual(row["n4"], "123456789012345678901234567890.5")
        XCTAssertEqual(row["n5"], "NaN")
        XCTAssertEqual(row["n6"], "0")
        XCTAssertEqual(row["ivp"], "infinity")
        XCTAssertEqual(row["ivn"], "-infinity")
        XCTAssertEqual(row["ivneg"], "-05:03:00")
        XCTAssertEqual(row["tsp"], "infinity")
        XCTAssertEqual(row["tsn"], "-infinity")
        XCTAssertEqual(row["dp"], "infinity")
        XCTAssertEqual(row["dn"], "-infinity")
        XCTAssertEqual(row["t"], "hi")
        XCTAssertEqual(row["vc"], "v")
        XCTAssertEqual(row["u"], "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
        XCTAssertEqual(row["jb"], "{\"a\": 1}")
        XCTAssertEqual(row["j"], "{\"a\":1}")
        XCTAssertEqual(row["d"], "2024-01-02")
        XCTAssertEqual(row["ts"], "2024-01-02T03:04:05.500Z")
        XCTAssertEqual(row["by"], "\\x0102")
        XCTAssertEqual(row["ta"], "{x,y}")
        XCTAssertEqual(row["ia"], "{1,2}")
        XCTAssertEqual(row["nul"], .some(nil))
        XCTAssertEqual(row["iv"], "1 day")
        XCTAssertEqual(row["iv2"], "1 year 2 mons 3 days 04:05:06.5")
        XCTAssertEqual(row["ip"], "<inet>")
    }

    func testIntrospectionAndPaging() async throws {
        _ = try await session.run("""
            create temp table "we""ird" (id serial primary key, name text not null default 'x', score int)
            """)
        _ = try await session.run("""
            insert into "we""ird" (name, score) select 'n' || g, g % 7 from generate_series(1, 250) g
            """)
        let tempSchema = try await session.run("select nspname from pg_namespace where oid = pg_my_temp_schema()")
        let schema = try XCTUnwrap(tempSchema.rows.first?.first ?? nil)

        let databases = try await session.databases()
        XCTAssertTrue(databases.contains("postgres"))
        let schemas = try await session.schemas()
        XCTAssertEqual(schemas.first, "public")

        let relations = try await session.relations(in: schema)
        let table = try XCTUnwrap(relations.first { $0.name == "we\"ird" })
        XCTAssertEqual(table.kind, .table)

        let columns = try await session.columns(of: table)
        XCTAssertEqual(columns.map(\.name), ["id", "name", "score"])
        XCTAssertEqual(columns.map(\.isPrimaryKey), [true, false, false])
        XCTAssertEqual(columns[1].nullable, false)
        XCTAssertEqual(columns[1].defaultValue, "'x'::text")

        let count = try await session.rowCount(of: table)
        XCTAssertEqual(count.value, 250)
        XCTAssertFalse(count.isEstimate)

        let page2 = try await session.page(of: table, columns: columns, request: PageRequest(limit: 100, offset: 100))
        XCTAssertEqual(page2.rows.count, 100)
        XCTAssertEqual(page2.rows.first?.first, "101")

        let sorted = try await session.page(
            of: table, columns: columns,
            request: PageRequest(limit: 5, orderBy: "name", ascending: false)
        )
        XCTAssertEqual(sorted.rows.first?[1], "n99")

        let empty = try await session.run("delete from \"we\"\"ird\" where id > 245")
        XCTAssertEqual(empty.commandTag, "DELETE 5")
        XCTAssertEqual(empty.rowsAffected, 5)
        XCTAssertTrue(empty.rows.isEmpty)

        let emptyPage = try await session.page(of: table, columns: columns, request: PageRequest(offset: 1000))
        XCTAssertEqual(emptyPage.columns, ["id", "name", "score"])
    }

    func testServerErrorsAreReadable() async throws {
        do {
            _ = try await session.run("select * from no_such_table")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("ERROR: relation \"no_such_table\" does not exist"),
                          error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("POSITION: 15"), error.localizedDescription)
        }
    }

    func testTypesWithoutBinaryOutputFallBackToText() async throws {
        let result = try await session.run("""
            select relname, relacl, null::int as n, 1 as relname from pg_class
            where relacl is not null order by 1 limit 3;
            """)
        XCTAssertEqual(result.columns, ["relname", "relacl", "n", "relname"])
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertTrue(result.rows[0][1]?.contains("=") == true, "\(result.rows[0])")
        XCTAssertNil(result.rows[0][2])
        XCTAssertEqual(result.rows[0][3], "1")
    }

    func testPagingSystemCatalogWithAclColumns() async throws {
        let relation = Relation(schema: "pg_catalog", name: "pg_class", kind: .table)
        let columns = try await session.columns(of: relation)
        let page = try await session.page(
            of: relation, columns: columns,
            request: PageRequest(limit: 20, orderBy: "relpages", ascending: false)
        )
        XCTAssertEqual(page.rows.count, 20)
        XCTAssertTrue(page.columns.contains("relacl"))
        // Sorted numerically on the original int column, not as text.
        let pages = page.rows.compactMap { $0[page.columns.firstIndex(of: "relpages")!] }.compactMap(Int.init)
        XCTAssertEqual(pages, pages.sorted(by: >))
    }

    func testRowLimitTruncates() async throws {
        let result = try await session.run("select g from generate_series(1, 50) g", maxRows: 10)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.truncated)
    }

    func testQuoteIdent() {
        XCTAssertEqual(quoteIdent("plain"), "\"plain\"")
        XCTAssertEqual(quoteIdent("a\"b"), "\"a\"\"b\"")
    }
}
