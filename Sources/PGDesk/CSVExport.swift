import AppKit
import PGDeskCore
import UniformTypeIdentifiers

/// Asks where to save, then writes the rows as CSV (UTF-8, header row, NULL as an empty field).
@MainActor
enum CSVExport {
    static func save(columns: [String], rows: [[String?]], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName + ".csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CSV.encode(columns: columns, rows: rows).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
