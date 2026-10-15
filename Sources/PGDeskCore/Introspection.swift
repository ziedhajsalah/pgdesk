import Foundation
import PostgresNIO

public struct Relation: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case table = "r", partitioned = "p", view = "v", materializedView = "m", foreign = "f"
    }
    public let schema: String
    public let name: String
    public let kind: Kind
    public var id: String { "\(schema).\(name)" }
}

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let defaultValue: String
    public let isPrimaryKey: Bool
    public var id: String { name }
}

public struct RowCount: Sendable {
    public let value: Int64
    /// True when taken from planner statistics instead of `count(*)`.
    public let isEstimate: Bool
}

public struct PageRequest: Hashable, Sendable {
    public var limit: Int
    public var offset: Int
    public var orderBy: String?
    public var ascending: Bool

    public init(limit: Int = 100, offset: Int = 0, orderBy: String? = nil, ascending: Bool = true) {
        self.limit = limit
        self.offset = offset
        self.orderBy = orderBy
        self.ascending = ascending
    }
}

/// Quotes an identifier for safe use in SQL: `my"table` becomes `"my""table"`.
public func quoteIdent(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

extension DatabaseSession {
    public func databases() async throws -> [String] {
        try await collect(
            "select datname from pg_database where not datistemplate and datallowconn order by datname",
            as: String.self
        )
    }

    /// Schemas with `public` first and system schemas last.
    public func schemas() async throws -> [String] {
        try await collect(
            """
            select nspname from pg_namespace
            where nspname not like 'pg_toast%' and nspname not like 'pg_temp%'
            order by case when nspname = 'public' then 0
                          when nspname in ('pg_catalog', 'information_schema') then 2
                          else 1 end, nspname
            """,
            as: String.self
        )
    }

    public func relations(in schema: String) async throws -> [Relation] {
        let rows = try await collect(
            """
            select c.relname::text, c.relkind::text from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = \(schema) and c.relkind in ('r', 'p', 'v', 'm', 'f')
            order by c.relname
            """,
            as: (String, String).self
        )
        return rows.compactMap { name, kind in
            Relation.Kind(rawValue: kind).map { Relation(schema: schema, name: name, kind: $0) }
        }
    }

    public func columns(of relation: Relation) async throws -> [ColumnInfo] {
        let rows = try await collect(
            """
            select a.attname::text,
                   format_type(a.atttypid, a.atttypmod),
                   not a.attnotnull,
                   coalesce(pg_get_expr(d.adbin, d.adrelid), ''),
                   coalesce(a.attnum = any(i.indkey), false)
            from pg_attribute a
            join pg_class c on c.oid = a.attrelid
            join pg_namespace n on n.oid = c.relnamespace
            left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
            left join pg_index i on i.indrelid = c.oid and i.indisprimary
            where n.nspname = \(relation.schema) and c.relname = \(relation.name)
              and a.attnum > 0 and not a.attisdropped
            order by a.attnum
            """,
            as: (String, String, Bool, String, Bool).self
        )
        return rows.map { ColumnInfo(name: $0.0, type: $0.1, nullable: $0.2, defaultValue: $0.3, isPrimaryKey: $0.4) }
    }

    /// Exact count for small relations; planner estimate above `exactLimit` rows.
    public func rowCount(of relation: Relation, exactLimit: Int64 = 200_000) async throws -> RowCount {
        if relation.kind != .view && relation.kind != .foreign {
            let estimates: [Int64] = try await collect(
                """
                select c.reltuples::int8 from pg_class c
                join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = \(relation.schema) and c.relname = \(relation.name)
                """,
                as: Int64.self
            )
            let estimate = estimates.first ?? -1
            if estimate > exactLimit {
                return RowCount(value: estimate, isEstimate: true)
            }
        }
        let result = try await run("select count(*) from \(qualifiedName(relation))")
        let value = result.rows.first?.first.flatMap { $0 }.flatMap { Int64($0) } ?? 0
        return RowCount(value: value, isEstimate: false)
    }

    /// One page of rows. Without an explicit sort, pages are ordered by primary key when there is one.
    /// Every column is cast to text, so values look exactly like psql output and types without
    /// a binary send function (aclitem, ...) still load. Sorting uses the original column type.
    public func page(of relation: Relation, columns: [ColumnInfo], request: PageRequest) async throws -> QueryResult {
        let select = columns.isEmpty
            ? "*"
            : columns.map { "_t.\(quoteIdent($0.name))::text as \(quoteIdent($0.name))" }.joined(separator: ", ")
        var sql = "select \(select) from \(qualifiedName(relation)) as _t"
        if let orderBy = request.orderBy {
            sql += " order by _t.\(quoteIdent(orderBy)) \(request.ascending ? "asc" : "desc") nulls last"
        } else {
            let keys = columns.filter(\.isPrimaryKey).map { "_t." + quoteIdent($0.name) }
            if !keys.isEmpty { sql += " order by " + keys.joined(separator: ", ") }
        }
        sql += " limit \(max(1, request.limit)) offset \(max(0, request.offset))"
        var result = try await run(sql, maxRows: request.limit)
        if result.columns.isEmpty { result.columns = columns.map(\.name) }
        return result
    }

    func qualifiedName(_ relation: Relation) -> String {
        quoteIdent(relation.schema) + "." + quoteIdent(relation.name)
    }

    private func collect<each T: PostgresDecodable>(
        _ query: PostgresQuery,
        as type: (repeat each T).Type
    ) async throws -> [(repeat each T)] {
        do {
            var output: [(repeat each T)] = []
            let rows = try await connection.query(query, logger: logger)
            for try await row in rows.decode(type) {
                output.append(row)
            }
            return output
        } catch {
            throw PGDeskError(error)
        }
    }
}
