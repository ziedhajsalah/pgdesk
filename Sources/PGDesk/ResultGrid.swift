import AppKit
import SwiftUI

/// A spreadsheet-style grid backed by NSTableView, which stays fast with many rows and wide tables.
/// ⌘C copies the selected rows as tab-separated text.
struct ResultGrid: NSViewRepresentable {
    struct Sort: Equatable {
        var column: String
        var ascending: Bool
    }

    /// A finished cell edit. `original` is the whole row as it was shown when editing started.
    struct Edit {
        var row: Int
        var column: Int
        var original: [String?]
        /// nil sets the cell to SQL NULL.
        var value: String?
    }

    let columns: [String]
    let rows: [[String?]]
    var sort: Sort?
    /// When set, clicking a column header asks the owner to sort by that column.
    var onSort: ((Sort) -> Void)?
    /// When set, cells can be edited: double-click edits in place (Return saves, Esc cancels,
    /// ⌥Return adds a newline), the context menu can set NULL. The owner saves the value
    /// and passes back the updated rows.
    var onEdit: ((Edit) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = GridTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.rowHeight = 20
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.copyRows = { [weak coordinator] indexes in
            coordinator?.tsv(for: indexes) ?? ""
        }
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table

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

        // Reloading would end an edit in progress; the new rows are applied when it finishes.
        if coordinator.editing != nil { return }

        let columnsChanged = coordinator.columns != columns || coordinator.sortable != (onSort != nil)
        if columnsChanged {
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
        if columnsChanged || coordinator.rows != rows {
            coordinator.rows = rows
            table.reloadData()
        }
    }

    /// Fits the header and the first rows' content, within sane limits.
    private static func width(for index: Int, header: String, rows: [[String?]]) -> CGFloat {
        var longest = header.count
        for row in rows.prefix(100) where index < row.count {
            longest = max(longest, min(row[index]?.count ?? 4, 60))
        }
        return min(max(CGFloat(longest) * 7.5 + 20, 60), 420)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: ResultGrid?
        var columns: [String] = []
        var rows: [[String?]] = []
        var sortable = false
        var isUpdating = false
        weak var table: NSTableView?

        struct Editing {
            var row: Int
            var column: Int
            var original: [String?]
            var lineCount: Int
            weak var field: NSTextField?
        }
        var editing: Editing?

        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// Rows are one line, except a row being edited with a multi-line value, which grows (up to 10 lines).
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let editing, editing.row == row, editing.lineCount > 1 else { return tableView.rowHeight }
            return tableView.rowHeight + CGFloat(min(editing.lineCount, 10) - 1) * 15
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let field = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = Self.cellID
                field.font = Self.font
                field.cell?.truncatesLastVisibleLine = true
                return field
            }()
            // Reused views may come from an edit.
            field.isEditable = false
            field.isSelectable = false
            field.drawsBackground = false
            field.delegate = nil
            field.lineBreakMode = .byTruncatingTail

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

        // MARK: - Editing

        @objc func doubleClicked(_ sender: NSTableView) {
            beginEditing(row: sender.clickedRow, column: sender.clickedColumn)
        }

        private func beginEditing(row: Int, column: Int) {
            guard parent?.onEdit != nil, editing == nil, let table,
                  row >= 0, row < rows.count, column >= 0, column < rows[row].count,
                  let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField
            else { return }
            // Seed with the real value, never the display string (which is clipped and has ↵ for newlines).
            let value = rows[row][column] ?? ""
            let lineCount = value.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
            editing = Editing(row: row, column: column, original: rows[row], lineCount: lineCount, field: field)
            if lineCount > 1 {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
            field.stringValue = value
            field.textColor = .labelColor
            field.lineBreakMode = lineCount > 1 ? .byCharWrapping : .byClipping
            field.usesSingleLineMode = false
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.delegate = self
            table.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(commit: false)
                return true
            }
            return false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let current = editing, let field = current.field else { return }
            let lineCount = field.stringValue.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
            guard lineCount != current.lineCount else { return }
            editing?.lineCount = lineCount
            field.lineBreakMode = lineCount > 1 ? .byCharWrapping : .byClipping
            table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: current.row))
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(commit: true)
        }

        private func finishEditing(commit: Bool) {
            guard let current = editing else { return }
            editing = nil
            let value = current.field?.stringValue ?? ""
            current.field?.abortEditing()
            table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: current.row))
            let original = current.original[current.column]
            // An untouched NULL cell reads back as "", which isn't a change.
            let changed = original.map { $0 != value } ?? !value.isEmpty
            if commit && changed {
                parent?.onEdit?(Edit(row: current.row, column: current.column, original: current.original, value: value))
            }
            // Show the latest rows (they may have changed while editing) and give focus back to the grid.
            if let parent { rows = parent.rows }
            table?.reloadData()
            if let table { table.window?.makeFirstResponder(table) }
        }

        // MARK: - Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, parent?.onEdit != nil else { return }
            let row = table.clickedRow, column = table.clickedColumn
            guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else { return }
            let edit = NSMenuItem(title: "Edit Cell", action: #selector(editClickedCell(_:)), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            let setNull = NSMenuItem(title: "Set to NULL", action: #selector(setClickedCellNull(_:)), keyEquivalent: "")
            setNull.target = self
            if rows[row][column] == nil { setNull.action = nil }
            menu.addItem(setNull)
        }

        @objc private func editClickedCell(_ sender: Any?) {
            guard let table else { return }
            beginEditing(row: table.clickedRow, column: table.clickedColumn)
        }

        @objc private func setClickedCellNull(_ sender: Any?) {
            guard let table, editing == nil else { return }
            let row = table.clickedRow, column = table.clickedColumn
            guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else { return }
            parent?.onEdit?(Edit(row: row, column: column, original: rows[row], value: nil))
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
