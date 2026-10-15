import AppKit
import SwiftUI

@main
struct PGDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PGDesk") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no app bundle), otherwise the window gets no keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct RootView: View {
    @State private var store = ConnectionStore()
    @State private var workspace: Workspace?

    var body: some View {
        if let workspace {
            WorkspaceView(workspace: workspace) {
                self.workspace = nil
                Task { await workspace.close() }
            }
        } else {
            ConnectionsView(store: store) { workspace = $0 }
        }
    }
}
