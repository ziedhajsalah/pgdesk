import AppKit
import SwiftUI

/// A spreadsheet-style grid backed by NSTableView, which stays fast with many rows and wide tables.
/// ⌘C copies the selected rows as tab-separated text.
struct ResultGrid: NSViewRepresentable {
    struct Sort: Equatable {
        var column: String
        var ascending: Bool
    }

    let columns: [String]
    let rows: [[String?]]
    var sort: Sort?
    /// When set, clicking a column header asks the owner to sort by that column.
    var onSort: ((Sort) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.rowHeight = 20
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copyRows = { [weak coordinator = context.coordinator] indexes in
            coordinator?.tsv(for: indexes) ?? ""
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = scroll.documentView as? NSTableView else { return }
        coordinator.parent = self
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        if coordinator.columns != columns || coordinator.sortable != (onSort != nil) {
            coordinator.columns = columns
            coordinator.sortable = onSort != nil
            table.tableColumns.forEach(table.removeTableColumn)
            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = name
                column.width = Self.width(for: index, header: name, rows: rows)
                column.minWidth = 40
                if onSort != nil {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                }
                table.addTableColumn(column)
            }
        }
        let descriptors = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
        if table.sortDescriptors != descriptors {
            table.sortDescriptors = descriptors
        }
        coordinator.rows = rows
        table.reloadData()
    }

    /// Fits the header and the first rows' content, within sane limits.
    private static func width(for index: Int, header: String, rows: [[String?]]) -> CGFloat {
        var longest = header.count
        for row in rows.prefix(100) where index < row.count {
            longest = max(longest, min(row[index]?.count ?? 4, 60))
        }
        return min(max(CGFloat(longest) * 7.5 + 20, 60), 420)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResultGrid?
        var columns: [String] = []
        var rows: [[String?]] = []
        var sortable = false
        var isUpdating = false

        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let field = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = Self.cellID
                field.font = Self.font
                field.lineBreakMode = .byTruncatingTail
                field.cell?.truncatesLastVisibleLine = true
                return field
            }()
            let value = index < rows[row].count ? rows[row][index] : nil
            if let value {
                field.stringValue = Self.singleLine(value)
                field.textColor = .labelColor
                field.toolTip = value.count > 40 ? String(value.prefix(2000)) : nil
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.toolTip = nil
            }
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let onSort = parent?.onSort,
                  let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            onSort(Sort(column: key, ascending: descriptor.ascending))
        }

        func tsv(for indexes: IndexSet) -> String {
            indexes.compactMap { index in
                guard index < rows.count else { return nil }
                return rows[index].map { $0 ?? "" }.joined(separator: "\t")
            }.joined(separator: "\n")
        }

        private static func singleLine(_ value: String) -> String {
            let clipped = value.count > 500 ? String(value.prefix(500)) + "…" : value
            return clipped.replacingOccurrences(of: "\n", with: "↵ ")
        }
    }
}

final class GridTableView: NSTableView {
    var copyRows: ((IndexSet) -> String)?

    @objc func copy(_ sender: Any?) {
        guard let copyRows, !selectedRowIndexes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyRows(selectedRowIndexes), forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}
