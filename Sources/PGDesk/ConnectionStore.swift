import Foundation
import Observation
import PGDeskCore

/// Saved connections, persisted as JSON in UserDefaults. Passwords go to the Keychain.
@MainActor @Observable
final class ConnectionStore {
    private static let key = "connections"

    private(set) var connections: [ConnectionConfig] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ConnectionConfig].self, from: data) {
            connections = saved
        }
        if connections.isEmpty {
            connections = [ConnectionConfig()]
            persist()
        }
    }

    func save(_ config: ConnectionConfig, password: String) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        Keychain.setPassword(password, for: config.id)
        persist()
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
