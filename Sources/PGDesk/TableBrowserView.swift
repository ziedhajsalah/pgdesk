import PGDeskCore
import SwiftUI

struct TableBrowserView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data", structure = "Structure"
        var id: String { rawValue }
    }

    let workspace: Workspace
    let database: String
    let relation: Relation

    @State private var mode = Mode.data
    @State private var columns: [ColumnInfo] = []
    @State private var result: QueryResult?
    @State private var count: RowCount?
    @State private var request = PageRequest()
    @State private var loading = false
    @State private var error: String?
    @State private var editError: String?
    @State private var saving = 0
    @State private var reloadToken = 0

    private static let pageSizes = [100, 500, 1000]

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .data:
                dataView
            case .structure:
                StructureView(columns: columns)
            }
        }
        .navigationTitle(relation.name)
        .navigationSubtitle("\(database) · \(relation.schema) · \(relation.kind.label)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    guard let result else { return }
                    CSVExport.save(columns: result.columns, rows: result.rows, suggestedName: relation.name)
                }
                .disabled(result == nil || mode != .data)
                .help("Save the rows on this page as CSV")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    .keyboardShortcut("r")
            }
        }
        .task(id: reloadToken) { await loadMetadata() }
        .task(id: Reload(request: request, token: reloadToken)) { await loadPage() }
    }

    private struct Reload: Hashable {
        var request: PageRequest
        var token: Int
    }

    @ViewBuilder
    private var dataView: some View {
        if let error {
            ScrollView {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if let result {
            if let editError {
                editErrorBanner(editError)
            }
            ResultGrid(
                columns: result.columns,
                rows: result.rows,
                sort: request.orderBy.map { ResultGrid.Sort(column: $0, ascending: request.ascending) },
                onSort: { sort in
                    request.orderBy = sort.column
                    request.ascending = sort.ascending
                    request.offset = 0
                },
                onEdit: isEditable ? save : nil
            )
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        pager
    }

    private func editErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark") { editError = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12))
    }

    /// Cells can be edited in tables with a primary key, when the grid shows exactly the table's columns.
    private var isEditable: Bool {
        RowEditing.isEditable(relation, columns: columns) && result?.columns == columns.map(\.name)
    }

    private func save(_ edit: ResultGrid.Edit) {
        let column = columns[edit.column].name
        saving += 1
        Task {
            defer { saving -= 1 }
            do {
                let session = try await workspace.session(for: database)
                let updated = try await session.updateCell(
                    of: relation, columns: columns, row: edit.original, column: column, value: edit.value
                )
                // The page may have changed while saving; find the row again by its primary key.
                let keys = columns.indices.filter { columns[$0].isPrimaryKey }
                let sameRow = { (row: [String?]) in keys.allSatisfy { row[$0] == edit.original[$0] } }
                if let rows = result?.rows {
                    let index = edit.row < rows.count && sameRow(rows[edit.row])
                        ? edit.row
                        : rows.firstIndex(where: sameRow)
                    if let index { result?.rows[index] = updated }
                }
                editError = nil
            } catch {
                editError = "Couldn't update \(column): \(error.localizedDescription)"
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Text(rangeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if loading || saving > 0 { ProgressView().controlSize(.small) }
            if !isEditable && result != nil && !columns.isEmpty {
                Label("Read-only", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .help(readOnlyReason)
            }
            Spacer()
            if request.orderBy != nil {
                Button("Clear Sort") {
                    request.orderBy = nil
                    request.offset = 0
                }
            }
            Picker("Page size", selection: $request.limit) {
                ForEach(Self.pageSizes, id: \.self) { Text("\($0) rows").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: request.limit) { request.offset = 0 }
            Button("Previous Page", systemImage: "chevron.left") {
                request.offset = max(0, request.offset - request.limit)
            }
            .labelStyle(.iconOnly)
            .disabled(request.offset == 0)
            .keyboardShortcut("[")
            Button("Next Page", systemImage: "chevron.right") {
                request.offset += request.limit
            }
            .labelStyle(.iconOnly)
            .disabled((result?.rows.count ?? 0) < request.limit)
            .keyboardShortcut("]")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var readOnlyReason: String {
        if relation.kind != .table && relation.kind != .partitioned { return "Only tables can be edited." }
        if relation.isSystem { return "System catalogs are read-only here." }
        return "Tables without a primary key are read-only: rows can't be identified safely."
    }

    private var rangeText: String {
        guard let result else { return " " }
        let total = count.map { $0.isEstimate ? "~\($0.value.formatted())" : $0.value.formatted() } ?? "…"
        if result.rows.isEmpty {
            return "No rows · \(total) total"
        }
        let first = request.offset + 1
        let last = request.offset + result.rows.count
        return "Rows \(first.formatted())–\(last.formatted()) of \(total)"
    }

    private func loadMetadata() async {
        do {
            let session = try await workspace.session(for: database)
            columns = try await session.columns(of: relation)
            count = try await session.rowCount(of: relation)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPage() async {
        loading = true
        defer { loading = false }
        do {
            let session = try await workspace.session(for: database)
            if columns.isEmpty {
                columns = try await session.columns(of: relation)
            }
            result = try await session.page(of: relation, columns: columns, request: request)
            error = nil
            editError = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StructureView: View {
    let columns: [ColumnInfo]

    var body: some View {
        Table(columns) {
            TableColumn("") { column in
                if column.isPrimaryKey {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.yellow)
                        .help("Primary key")
                }
            }
            .width(24)
            TableColumn("Column", value: \.name)
            TableColumn("Type") { Text($0.type).monospaced() }
            TableColumn("Nullable") { Text($0.nullable ? "yes" : "no") }
                .width(70)
            TableColumn("Default") { Text($0.defaultValue).monospaced().foregroundStyle(.secondary) }
        }
    }
}
