import Foundation
import PostgresNIO

extension Relation {
    /// System catalogs have primary keys too, but editing them by hand can break the server.
    public var isSystem: Bool {
        schema == "pg_catalog" || schema == "information_schema" || schema.hasPrefix("pg_toast")
    }
}

/// One cell edit: set `column` to `value` (nil is SQL NULL) in the row identified by its primary key.
public struct CellUpdate: Sendable {
    public let sql: String
    /// Text values for `$1, $2, …`: the new value first, then the primary key values.
    public let binds: [String?]
}

public enum RowEditing {
    /// Rows can be edited in plain and partitioned tables that have a primary key, outside system schemas.
    public static func isEditable(_ relation: Relation, columns: [ColumnInfo]) -> Bool {
        (relation.kind == .table || relation.kind == .partitioned)
            && !relation.isSystem
            && columns.contains(where: \.isPrimaryKey)
    }

    /// Builds `UPDATE … SET col = $1 WHERE pk = $2 … RETURNING every column as text`.
    /// `row` holds the row's current values as text, aligned with `columns`.
    /// Parameters are sent untyped, so the server reads them with each column's own input function,
    /// the same text the page showed (pages cast every column to text).
    public static func update(
        _ relation: Relation, columns: [ColumnInfo], row: [String?], column: String, value: String?
    ) throws -> CellUpdate {
        guard isEditable(relation, columns: columns) else {
            throw PGDeskError(message: "\(relation.name) can't be edited: it needs a primary key.")
        }
        guard row.count == columns.count else {
            throw PGDeskError(message: "The row doesn't match the table's columns. Refresh and try again.")
        }
        guard columns.contains(where: { $0.name == column }) else {
            throw PGDeskError(message: "Column \(column) not found.")
        }
        var binds: [String?] = [value]
        var conditions: [String] = []
        for (info, current) in zip(columns, row) where info.isPrimaryKey {
            guard let current else {
                throw PGDeskError(message: "Primary key \(info.name) is NULL, so the row can't be identified.")
            }
            binds.append(current)
            conditions.append("_t.\(quoteIdent(info.name)) = $\(binds.count)")
        }
        let returning = columns.map { "_t.\(quoteIdent($0.name))::text" }.joined(separator: ", ")
        let target = quoteIdent(relation.schema) + "." + quoteIdent(relation.name)
        let sql = "update \(target) as _t set \(quoteIdent(column)) = $1 where "
            + conditions.joined(separator: " and ")
            + " returning \(returning)"
        return CellUpdate(sql: sql, binds: binds)
    }
}

/// A text parameter with no declared type (OID 0), so the server infers it from context:
/// `set col = $1` takes the column's type, `where id = $2` takes the key's type.
struct UntypedText: PostgresNonThrowingEncodable {
    static var psqlType: PostgresDataType { .null }
    static var psqlFormat: PostgresFormat { .text }

    let value: String

    func encode<JSONEncoder: PostgresJSONEncoder>(into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>) {
        byteBuffer.writeString(value)
    }
}

extension DatabaseSession {
    /// Updates one cell and returns the row as stored afterwards (every column as text).
    public func updateCell(
        of relation: Relation, columns: [ColumnInfo], row: [String?], column: String, value: String?
    ) async throws -> [String?] {
        let update = try RowEditing.update(relation, columns: columns, row: row, column: column, value: value)
        var bindings = PostgresBindings(capacity: update.binds.count)
        for bind in update.binds {
            if let bind {
                bindings.append(UntypedText(value: bind))
            } else {
                bindings.appendNull()
            }
        }
        var updated: [[String?]] = []
        do {
            let rows = try await connection.query(PostgresQuery(unsafeSQL: update.sql, binds: bindings), logger: logger)
            for try await row in rows {
                updated.append(row.map(CellFormatter.format))
            }
        } catch {
            throw PGDeskError(error)
        }
        guard let first = updated.first else {
            throw PGDeskError(message: "No row was updated: it may have been deleted or its key changed. Refresh and try again.")
        }
        return first
    }
}
