import PGDeskCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let onDisconnect: () -> Void

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            switch workspace.selection {
            case .query(let database):
                QueryEditorView(workspace: workspace, database: database)
                    .id(database)
            case .relation(let database, let relation):
                TableBrowserView(workspace: workspace, database: database, relation: relation)
                    .id(SidebarItem.relation(database: database, relation))
            case nil:
                ContentUnavailableView("Select a table or a query editor", systemImage: "tablecells")
            }
        }
        .navigationTitle(workspace.config.name)
        .navigationSubtitle("\(workspace.config.user)@\(workspace.config.host):\(String(workspace.config.port))")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Reload Schema", systemImage: "arrow.clockwise") {
                    Task { await workspace.reload() }
                }
                Button("Disconnect", systemImage: "eject", action: onDisconnect)
            }
        }
    }
}

/// Databases → schemas → tables, as a native outline. Children load lazily: an expanded node
/// first shows a "Loading…" row, and that row appearing triggers the fetch.
private struct SidebarView: View {
    let workspace: Workspace

    var body: some View {
        List(tree, children: \.children, selection: selection) { node in
            row(for: node)
        }
    }

    /// Only query editors and relations are selectable; clicks on other rows keep the current selection.
    private var selection: Binding<OutlineNode.ID?> {
        Binding(
            get: { workspace.selection.map(OutlineNode.ID.item) },
            set: { id in
                if case .item(let item)? = id { workspace.selection = item }
            }
        )
    }

    @ViewBuilder
    private func row(for node: OutlineNode) -> some View {
        switch node.id {
        case .database(let name):
            Label(name, systemImage: "cylinder")
        case .schema(_, let name):
            Label(name, systemImage: "folder")
        case .item(.query):
            Label("Query", systemImage: "terminal")
        case .item(.relation(_, let relation)):
            Label(relation.name, systemImage: relation.kind.symbol)
                .help("\(relation.schema).\(relation.name) · \(relation.kind.label)")
        case .loading(let database, let schema):
            Text("Loading…")
                .foregroundStyle(.secondary)
                .task { await load(database: database, schema: schema) }
        case .message(_, let text, let isError):
            Text(text)
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(3)
                .help(text)
        }
    }

    private func load(database: String, schema: String?) async {
        guard let node = workspace.databases.first(where: { $0.name == database }) else { return }
        if let schema {
            if let schemaNode = node.schemas?.first(where: { $0.name == schema }), schemaNode.relations == nil {
                await workspace.loadRelations(schemaNode, in: database)
            }
        } else if node.schemas == nil {
            await workspace.loadSchemas(node)
        }
    }

    private var tree: [OutlineNode] {
        workspace.databases.map { database in
            var children = [OutlineNode(id: .item(.query(database: database.name)))]
            if let error = database.error {
                children.append(.message(database.name, error, isError: true))
            } else if let schemas = database.schemas {
                children += schemas.map { schemaNode(database.name, $0) }
            } else {
                children.append(OutlineNode(id: .loading(database: database.name, schema: nil)))
            }
            return OutlineNode(id: .database(database.name), children: children)
        }
    }

    private func schemaNode(_ database: String, _ schema: SchemaNode) -> OutlineNode {
        let children: [OutlineNode]
        if let error = schema.error {
            children = [.message("\(database).\(schema.name)", error, isError: true)]
        } else if let relations = schema.relations {
            children = relations.isEmpty
                ? [.message("\(database).\(schema.name)", "No tables", isError: false)]
                : relations.map { OutlineNode(id: .item(.relation(database: database, $0))) }
        } else {
            children = [OutlineNode(id: .loading(database: database, schema: schema.name))]
        }
        return OutlineNode(id: .schema(database: database, schema.name), children: children)
    }
}

private struct OutlineNode: Identifiable {
    enum ID: Hashable {
        case database(String)
        case schema(database: String, String)
        case item(SidebarItem)
        case loading(database: String, schema: String?)
        case message(parent: String, String, isError: Bool)
    }

    let id: ID
    var children: [OutlineNode]? = nil

    static func message(_ parent: String, _ text: String, isError: Bool) -> OutlineNode {
        OutlineNode(id: .message(parent: parent, text, isError: isError))
    }
}

extension Relation.Kind {
    var symbol: String {
        switch self {
        case .table, .partitioned: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreign: "link"
        }
    }

    var label: String {
        switch self {
        case .table: "table"
        case .partitioned: "partitioned table"
        case .view: "view"
        case .materializedView: "materialized view"
        case .foreign: "foreign table"
        }
    }
}
