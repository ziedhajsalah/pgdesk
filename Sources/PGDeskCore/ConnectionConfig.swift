import Foundation

/// Mirrors libpq's sslmode. `prefer` and `require` encrypt without checking the certificate;
/// only `verifyFull` protects against a man-in-the-middle, so use it for remote servers.
public enum SSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disable, prefer, require
    case verifyFull = "verify-full"
    public var id: String { rawValue }
}

/// A saved connection. The password lives in the Keychain, keyed by `id`.
public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var sslMode: SSLMode

    public init(
        id: UUID = UUID(),
        name: String = "Local",
        host: String = "localhost",
        port: Int = 5432,
        user: String = NSUserName(),
        database: String = "postgres",
        sslMode: SSLMode = .disable
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.sslMode = sslMode
    }

    /// Same server and credentials, different database.
    public func with(database: String) -> ConnectionConfig {
        var copy = self
        copy.database = database
        return copy
    }
}
