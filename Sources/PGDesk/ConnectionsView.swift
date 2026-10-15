import PGDeskCore
import SwiftUI

struct ConnectionsView: View {
    let store: ConnectionStore
    let onConnect: (Workspace) -> Void

    @State private var selectedID: UUID?
    @State private var draft = ConnectionConfig()
    @State private var password = ""
    @State private var portText = "5432"
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            List(store.connections, selection: $selectedID) { config in
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name).font(.headline)
                    Text("\(config.user)@\(config.host):\(String(config.port))/\(config.database)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(config.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button("New Connection", systemImage: "plus") {
                        let config = ConnectionConfig(name: "New Connection")
                        store.save(config, password: "")
                        selectedID = config.id
                    }
                }
            }
        } detail: {
            if selectedID != nil {
                form
            } else {
                ContentUnavailableView("No connection selected", systemImage: "cylinder.split.1x2")
            }
        }
        .navigationTitle("Connections")
        .onAppear { selectedID = selectedID ?? store.connections.first?.id }
        .onChange(of: selectedID, initial: true) { load() }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Host", text: $draft.host)
                TextField("Port", text: $portText)
                TextField("User", text: $draft.user)
                SecureField("Password", text: $password, prompt: Text("none"))
                TextField("Database", text: $draft.database)
                Picker("SSL", selection: $draft.sslMode) {
                    ForEach(SSLMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("prefer and require encrypt but don't verify the server certificate. Use verify-full for remote servers.")
            }
            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Delete", role: .destructive) {
                    store.delete(draft.id)
                    selectedID = store.connections.first?.id
                }
                .disabled(store.connections.count <= 1)
                Spacer()
                if connecting { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func load() {
        guard let id = selectedID, let config = store.connections.first(where: { $0.id == id }) else { return }
        draft = config
        portText = String(config.port)
        password = Keychain.password(for: id) ?? ""
        error = nil
    }

    private func save() {
        draft.port = Int(portText) ?? 5432
        portText = String(draft.port)
        store.save(draft, password: password)
    }

    private func connect() {
        save()
        let config = draft
        let password = password
        connecting = true
        error = nil
        Task {
            do {
                let workspace = try await Workspace.open(config: config, password: password)
                onConnect(workspace)
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}
