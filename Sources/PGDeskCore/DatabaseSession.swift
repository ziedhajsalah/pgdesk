import Foundation
import Logging
import NIOConcurrencyHelpers
import PostgresNIO

public struct QueryResult: Sendable {
    public var columns: [String]
    /// Display strings; `nil` is SQL NULL.
    public var rows: [[String?]]
    public var commandTag: String
    public var rowsAffected: Int?
    public var duration: Duration
    /// True when more rows came back than `maxRows` and the rest were dropped.
    public var truncated: Bool
}

public struct PGDeskError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    /// Pulls the server's message, detail and hint out of PostgresNIO errors,
    /// whose default description hides them.
    public init(_ error: any Error) {
        if let error = error as? PGDeskError {
            self = error
        } else if let psql = error as? PSQLError {
            if let info = psql.serverInfo, let message = info[.message] {
                self.message = Self.format(
                    severity: info[.severity], message: message,
                    detail: info[.detail], hint: info[.hint], position: info[.position]
                )
            } else if let underlying = psql.underlying {
                self.message = "\(psql.code): \(underlying)"
            } else {
                self.message = "\(psql.code)"
            }
        } else if case .server(let server)? = error as? PostgresError, let message = server.fields[.message] {
            // The EventLoopFuture-based query API converts PSQLError into this legacy type.
            self.message = Self.format(
                severity: server.fields[.severity], message: message,
                detail: server.fields[.detail], hint: server.fields[.hint], position: server.fields[.position]
            )
        } else {
            self.message = String(describing: error)
        }
    }

    private static func format(severity: String?, message: String, detail: String?, hint: String?, position: String?) -> String {
        var lines = ["\(severity ?? "ERROR"): \(message)"]
        if let detail { lines.append("DETAIL: \(detail)") }
        if let hint { lines.append("HINT: \(hint)") }
        if let position { lines.append("POSITION: \(position)") }
        return lines.joined(separator: "\n")
    }

    public init(message: String) {
        self.message = message
    }
}

/// One open connection to one database.
public final class DatabaseSession: Sendable {
    public let config: ConnectionConfig
    let connection: PostgresConnection
    let logger: Logger

    private static let nextID = NIOLockedValueBox(0)

    init(config: ConnectionConfig, connection: PostgresConnection, logger: Logger) {
        self.config = config
        self.connection = connection
        self.logger = logger
    }

    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> DatabaseSession {
        let logger = Logger(label: "pgdesk")
        do {
            let tls: PostgresConnection.Configuration.TLS
            switch config.sslMode {
            case .disable:
                tls = .disable
            case .prefer, .require:
                // Like libpq's sslmode=prefer/require: encrypt, but don't verify the certificate.
                var tlsConfig = TLSConfiguration.makeClientConfiguration()
                tlsConfig.certificateVerification = .none
                let context = try NIOSSLContext(configuration: tlsConfig)
                tls = config.sslMode == .prefer ? .prefer(context) : .require(context)
            }
            let configuration = PostgresConnection.Configuration(
                host: config.host,
                port: config.port,
                username: config.user,
                password: password?.isEmpty == true ? nil : password,
                database: config.database,
                tls: tls
            )
            let id = nextID.withLockedValue { $0 += 1; return $0 }
            let connection = try await PostgresConnection.connect(configuration: configuration, id: id, logger: logger)
            return DatabaseSession(config: config, connection: connection, logger: logger)
        } catch {
            throw PGDeskError(error)
        }
    }

    public func close() async {
        try? await connection.close()
    }

    /// Runs one SQL statement and returns its rows as display strings.
    /// Rows are formatted as they stream in and only the first `maxRows` are kept,
    /// so a huge result can't exhaust memory.
    public func run(_ sql: String, maxRows: Int = 10_000) async throws -> QueryResult {
        struct State {
            var columns: [String] = []
            var rows: [[String?]] = []
            var total = 0
            var metadata: PostgresQueryMetadata?
        }
        let start = ContinuousClock.now
        let state = NIOLockedValueBox(State())
        do {
            try await connection.query(sql, [], onMetadata: { metadata in
                state.withLockedValue { $0.metadata = metadata }
            }, onRow: { row in
                state.withLockedValue { state in
                    state.total += 1
                    if state.columns.isEmpty { state.columns = row.map(\.columnName) }
                    if state.rows.count < maxRows { state.rows.append(row.map(CellFormatter.format)) }
                }
            }).get()
        } catch {
            let wrapped = PGDeskError(error)
            if wrapped.message.contains("no binary output function available"),
               let textResult = try? await runAsText(sql, maxRows: maxRows) {
                return textResult
            }
            throw wrapped
        }
        let result = state.withLockedValue { $0 }
        let command = result.metadata?.command ?? ""
        let affected = result.metadata?.rows
        return QueryResult(
            columns: result.columns,
            rows: result.rows,
            commandTag: affected.map { "\(command) \($0)" } ?? command,
            rowsAffected: affected,
            duration: ContinuousClock.now - start,
            truncated: result.total > maxRows
        )
    }

    /// Fallback for queries returning a type with no binary output function (e.g. aclitem):
    /// PostgresNIO always asks for binary results, so re-run the query wrapped to return
    /// every column as text via json_each_text, which keeps column order and duplicate names.
    /// Only works for queries that can be a subquery (SELECT, VALUES, TABLE).
    private func runAsText(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = ContinuousClock.now
        let nullMarker = "\u{1F}pgdesk-null\u{1F}"
        var inner = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while inner.hasSuffix(";") {
            inner = String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let wrapped = """
            select array(select key from json_each_text(row_to_json(_q))) as k,
                   array(select coalesce(value, '\(nullMarker)') from json_each_text(row_to_json(_q))) as v
            from (\(inner)
            ) as _q
            """
        var columns: [String] = []
        var rows: [[String?]] = []
        var total = 0
        let sequence = try await connection.query(PostgresQuery(unsafeSQL: wrapped), logger: logger)
        for try await (keys, values) in sequence.decode(([String], [String]).self) {
            total += 1
            if columns.isEmpty { columns = keys }
            if rows.count < maxRows {
                rows.append(values.map { $0 == nullMarker ? nil : $0 })
            }
        }
        return QueryResult(
            columns: columns,
            rows: rows,
            commandTag: "SELECT \(total)",
            rowsAffected: total,
            duration: ContinuousClock.now - start,
            truncated: total > maxRows
        )
    }
}
