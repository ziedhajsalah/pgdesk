import AppKit
import PGDeskCore
import SwiftUI

struct QueryEditorView: View {
    let workspace: Workspace
    let database: String

    @State private var selection = NSRange(location: 0, length: 0)
    @State private var result: QueryResult?
    @State private var error: String?
    @State private var running = false
    @State private var runningSession: DatabaseSession?
    @State private var cancelling = false

    private var text: Binding<String> {
        Binding(
            get: { workspace.queryTexts[database, default: "select now();"] },
            set: { workspace.queryTexts[database] = $0 }
        )
    }

    var body: some View {
        VSplitView {
            SQLTextView(text: text, selection: $selection)
                .frame(minHeight: 100, idealHeight: 220)
            VStack(spacing: 0) {
                output
                Divider()
                statusBar
            }
            .frame(minHeight: 120)
        }
        .navigationTitle("Query")
        .navigationSubtitle(database)
        .toolbar {
            ToolbarItem {
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    guard let result else { return }
                    CSVExport.save(columns: result.columns, rows: result.rows, suggestedName: "query")
                }
                .disabled(result?.columns.isEmpty ?? true)
                .help("Save the result as CSV (only the rows shown, at most 10,000)")
            }
            ToolbarItem {
                if running {
                    Button("Cancel", systemImage: "stop.fill", action: cancel)
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(cancelling || runningSession == nil)
                        .help("Cancel the running query (⌘.)")
                } else {
                    Button(selection.length > 0 ? "Run Selection" : "Run", systemImage: "play.fill", action: run)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Run (⌘↩). Runs only the selected text when there is a selection.")
                }
            }
        }
    }

    @ViewBuilder
    private var output: some View {
        if let error {
            ScrollView {
                Text(error)
                    .font(.body.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if let result, !result.columns.isEmpty {
            ResultGrid(columns: result.columns, rows: result.rows)
        } else if let result {
            Text(result.commandTag)
                .font(.title3.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Press ⌘↩ to run")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack {
            if running {
                ProgressView().controlSize(.small)
                Text(cancelling ? "Cancelling…" : "Running…")
            } else if let result {
                Text(summary(result))
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func summary(_ result: QueryResult) -> String {
        let ms = result.duration.components.seconds * 1000 + result.duration.components.attoseconds / 1_000_000_000_000_000
        var parts = [result.commandTag, "\(ms) ms"]
        if result.truncated {
            parts.append("showing first \(result.rows.count.formatted()) rows")
        }
        return parts.joined(separator: " · ")
    }

    private func run() {
        let full = text.wrappedValue as NSString
        let range = selection.length > 0 && NSMaxRange(selection) <= full.length
            ? selection
            : NSRange(location: 0, length: full.length)
        let sql = full.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty, !running else { return }
        running = true
        error = nil
        Task {
            do {
                let session = try await workspace.session(for: database)
                runningSession = session
                result = try await session.run(sql)
            } catch let error as PGDeskError where error.isQueryCancelled {
                result = nil
                self.error = "Query cancelled."
            } catch {
                result = nil
                self.error = error.localizedDescription
            }
            running = false
            runningSession = nil
            cancelling = false
        }
    }

    private func cancel() {
        guard let session = runningSession, !cancelling else { return }
        cancelling = true
        Task {
            do {
                try await session.cancelRunningQuery()
            } catch {
                self.error = "Couldn't cancel: \(error.localizedDescription)"
                cancelling = false
            }
        }
    }
}

/// Plain-text NSTextView: SwiftUI's TextEditor turns quotes into smart quotes, which breaks SQL.
/// Syntax colours are foreground-colour attributes on the text storage. After each edit the whole
/// text is re-lexed (one fast pass over UTF-16) but only the range whose tokens changed is recoloured,
/// so typing stays fast in large scripts.
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = Coordinator.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textStorage?.delegate = context.coordinator
        textView.string = text
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: SQLTextView
        /// Tokens of the current text, to find what changed after the next edit.
        private var tokens: [SQLToken] = []
        static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        init(_ parent: SQLTextView) { self.parent = parent }

        private static func color(for kind: SQLToken.Kind) -> NSColor {
            switch kind {
            case .keyword: .systemPink
            case .string: .systemRed
            case .number: .systemBlue
            case .comment: .secondaryLabelColor
            }
        }

        func textStorage(
            _ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
            range edited: NSRange, changeInLength delta: Int
        ) {
            guard mask.contains(.editedCharacters) else { return }
            let string = storage.string as NSString
            var units = [UInt16](repeating: 0, count: string.length)
            string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
            let new = units.withUnsafeBufferPointer { SQLHighlighter.tokens(in: $0) }
            let dirty = SQLHighlighter.dirtyRange(old: tokens, new: new, edited: edited, changeInLength: delta)
            tokens = new
            guard dirty.length > 0, NSMaxRange(dirty) <= string.length else { return }

            // setAttributes replaces the old colour runs in one step; removing or overwriting them
            // run by run is quadratic in NSTextStorage (1.7 s instead of 45 ms for 1 MB).
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: dirty)
            // First token that ends inside the dirty range.
            var low = 0, high = new.count
            while low < high {
                let mid = (low + high) / 2
                if new[mid].end <= dirty.location { low = mid + 1 } else { high = mid }
            }
            for token in new[low...] {
                guard token.location < NSMaxRange(dirty) else { break }
                let range = NSIntersectionRange(token.range, dirty)
                if range.length > 0 {
                    storage.addAttribute(.foregroundColor, value: Self.color(for: token.kind), range: range)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selection = textView.selectedRange()
        }
    }
}
