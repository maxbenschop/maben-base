import BaseCore
import Foundation

/// One open connection: the driver, its SSH tunnel, and a serial queue that every database call runs on,
/// so the UI never waits and the connection is never used from two threads at once.
/// A connection's secrets, kept in the Keychain: the database password, the SSH password or key passphrase,
/// and the client certificate's password.
struct Secrets: Sendable {
    var password: String?
    var ssh: String?
    var certificate: String?

    static func load(_ id: UUID) -> Secrets {
        Secrets(password: Keychain.password(account: id.uuidString), ssh: Keychain.password(account: id.uuidString + ".ssh"),
                certificate: Keychain.password(account: id.uuidString + ".p12"))
    }

    func save(_ id: UUID) {
        Keychain.set(password, account: id.uuidString)
        Keychain.set(ssh, account: id.uuidString + ".ssh")
        Keychain.set(certificate, account: id.uuidString + ".p12")
    }
}

final class Session: @unchecked Sendable {
    let config: ConnectionConfig
    let secrets: Secrets
    /// For the engine's own tools (pg_dump, mysqldump), which sign in themselves.
    var password: String? { secrets.password }
    private var driver: Driver
    private var tunnel: SSHTunnel?
    private let queue = DispatchQueue(label: "gg.maben.base.session", qos: .userInitiated)
    private var lost = false
    /// The driver that's running right now, for cancel().
    private let lock = NSLock()
    private var running: Driver?

    let kind: DatabaseKind
    let dialect: Dialect
    private(set) var serverVersion: String

    private init(config: ConnectionConfig, secrets: Secrets, driver: Driver, tunnel: SSHTunnel?) {
        self.config = config
        self.secrets = secrets
        self.driver = driver
        self.tunnel = tunnel
        kind = driver.kind
        dialect = driver.dialect
        serverVersion = driver.serverVersion
    }

    /// Connects off the main thread.
    static func open(_ config: ConnectionConfig, secrets: Secrets) async throws -> Session {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (driver, tunnel) = try connect(config, secrets: secrets, database: nil)
                    cont.resume(returning: Session(config: config, secrets: secrets, driver: driver, tunnel: tunnel))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func connect(_ config: ConnectionConfig, secrets: Secrets, database: String?) throws -> (Driver, SSHTunnel?) {
        if config.sshEnabled && config.kind != .sqlite && !config.host.hasPrefix("/") {
            let tunnel = try SSHTunnel(config: config, secret: secrets.ssh)
            do {
                return (try Connector.open(config, password: secrets.password, host: "127.0.0.1", port: tunnel.localPort, database: database,
                                           certificatePassword: secrets.certificate), tunnel)
            } catch {
                tunnel.close()
                throw error
            }
        }
        return (try Connector.open(config, password: secrets.password, database: database, certificatePassword: secrets.certificate), nil)
    }

    /// Runs work on the connection's queue. After a lost connection, the next call reconnects first.
    func run<T>(_ work: @escaping (Driver) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                do {
                    if lost {
                        let database = driver.currentDatabase
                        driver.close()
                        tunnel?.close()
                        (driver, tunnel) = try Self.connect(config, secrets: secrets, database: database)
                        lost = false
                    }
                    lock.lock(); running = driver; lock.unlock()
                    defer { lock.lock(); running = nil; lock.unlock() }
                    cont.resume(returning: try work(driver))
                } catch {
                    if let e = error as? DatabaseError, e.message.hasPrefix("The connection was lost") || e.message.hasPrefix("The connection was closed") {
                        lost = true
                    }
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        lock.lock(); let d = running; lock.unlock()
        d?.cancel()
    }

    func close() {
        queue.async { [self] in
            driver.close()
            tunnel?.close()
        }
    }

    /// Where the engine's tools should connect: the SSH tunnel's local end, or the server itself.
    var endpoint: (host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        if let tunnel { return ("127.0.0.1", tunnel.localPort) }
        return (config.host, config.port)
    }
}
