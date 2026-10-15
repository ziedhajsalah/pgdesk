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
                Button(selection.length > 0 ? "Run Selection" : "Run", systemImage: "play.fill", action: run)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running)
                    .help("Run (⌘↩). Runs only the selected text when there is a selection.")
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
                Text("Running…")
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
        guard !sql.isEmpty else { return }
        running = true
        error = nil
        Task {
            do {
                let session = try await workspace.session(for: database)
                result = try await session.run(sql)
            } catch {
                result = nil
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

/// Plain-text NSTextView: SwiftUI's TextEditor turns quotes into smart quotes, which breaks SQL.
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextView

        init(_ parent: SQLTextView) { self.parent = parent }

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
