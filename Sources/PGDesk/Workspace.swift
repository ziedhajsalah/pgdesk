import Foundation
import Observation
import PGDeskCore

enum SidebarItem: Hashable {
    case query(database: String)
    case relation(database: String, Relation)
}

@MainActor @Observable
final class DatabaseNode: Identifiable {
    nonisolated let name: String
    var schemas: [SchemaNode]?
    var error: String?
    nonisolated var id: String { name }

    init(name: String) { self.name = name }
}

@MainActor @Observable
final class SchemaNode: Identifiable {
    nonisolated let name: String
    var relations: [Relation]?
    var error: String?
    nonisolated var id: String { name }

    init(name: String) { self.name = name }
}

/// An open connection to a server: the sidebar tree plus one session per database.
/// Postgres can't read another database's catalog, so each expanded database gets its own connection.
@MainActor @Observable
final class Workspace {
    let config: ConnectionConfig
    private let password: String?
    var databases: [DatabaseNode] = []
    var selection: SidebarItem?
    var queryTexts: [String: String] = [:]

    private var sessions: [String: DatabaseSession] = [:]
    private var pending: [String: Task<DatabaseSession, any Error>] = [:]

    private init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    static func open(config: ConnectionConfig, password: String?) async throws -> Workspace {
        let session = try await DatabaseSession.connect(config, password: password)
        let names: [String]
        do {
            names = try await session.databases()
        } catch {
            await session.close()
            throw error
        }
        let workspace = Workspace(config: config, password: password)
        workspace.sessions[config.database] = session
        workspace.databases = names.map(DatabaseNode.init)
        workspace.selection = .query(database: config.database)
        return workspace
    }

    func session(for database: String) async throws -> DatabaseSession {
        if let session = sessions[database] { return session }
        if let task = pending[database] { return try await task.value }
        let config = config.with(database: database)
        let password = password
        let task = Task { try await DatabaseSession.connect(config, password: password) }
        pending[database] = task
        defer { pending[database] = nil }
        let session = try await task.value
        sessions[database] = session
        return session
    }

    func loadSchemas(_ node: DatabaseNode) async {
        do {
            let names = try await session(for: node.name).schemas()
            node.schemas = names.map(SchemaNode.init)
            node.error = nil
        } catch {
            node.error = error.localizedDescription
        }
    }

    func loadRelations(_ schema: SchemaNode, in database: String) async {
        do {
            schema.relations = try await session(for: database).relations(in: schema.name)
            schema.error = nil
        } catch {
            schema.error = error.localizedDescription
        }
    }

    func reload() async {
        for node in databases where node.schemas != nil {
            await loadSchemas(node)
        }
    }

    func close() async {
        for session in sessions.values {
            await session.close()
        }
        sessions = [:]
    }
}
