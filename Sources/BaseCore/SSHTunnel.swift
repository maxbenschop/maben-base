import Foundation

/// A local port forward through the system `ssh`, so ~/.ssh/config, the agent, jump hosts and
/// known_hosts all work as they do in Terminal. A password or key passphrase, when given, is handed to
/// ssh through a one-off askpass helper (never on the command line); ssh never asks interactively.
public final class SSHTunnel {
    public let localPort: Int
    private let process: Process
    private let errors = Pipe()

    public init(config: ConnectionConfig, secret: String? = nil) throws {
        localPort = try Self.freePort()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let secret = secret.flatMap { $0.isEmpty ? nil : $0 }
        var args = [
            "-N", "-T",
            "-o", secret == nil ? "BatchMode=yes" : "NumberOfPasswordPrompts=1",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "127.0.0.1:\(localPort):\(config.host):\(config.port)",
        ]
        if config.sshPort != 22 { args += ["-p", "\(config.sshPort)"] }
        if config.sshUsePassword {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        } else if !config.sshKeyPath.isEmpty {
            args += ["-i", (config.sshKeyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        var askpass: URL?
        if let secret {
            // A tiny script ssh runs to get the secret; the secret itself travels in its environment.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-askpass-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = dir.appendingPathComponent("askpass")
            // The secret goes as hex: environment values can have their Unicode rewritten on the way (é → e + ´).
            try "#!/bin/sh\nprintf '%s' \"$MB_SSH_SECRET_HEX\" | /usr/bin/xxd -r -p\necho\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            askpass = dir
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env["MB_SSH_SECRET_HEX"] = Array(secret.utf8).map { String(format: "%02x", $0) }.joined()
            process.environment = env
        }
        defer { if let askpass { try? FileManager.default.removeItem(at: askpass) } }
        args.append(config.sshUser.isEmpty ? config.sshHost : "\(config.sshUser)@\(config.sshHost)")
        // MB_SSH_DEBUG=1: ssh explains itself in the error message.
        if ProcessInfo.processInfo.environment["MB_SSH_DEBUG"] != nil { args.insert("-v", at: 0) }
        process.arguments = args
        process.standardError = errors
        // Keep reading ssh's messages so its pipe never fills up during a long session.
        let collected = Collected()
        errors.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        Self.register(process)

        // Wait until the forward accepts connections, or ssh gives up.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !process.isRunning {
                usleep(100_000)
                let message = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DatabaseError("The SSH tunnel didn't start.", detail: message.isEmpty ? nil : message)
            }
            if Self.canConnect(port: localPort) { return }
            usleep(100_000)
        }
        close()
        throw DatabaseError("The SSH tunnel took too long to start.")
    }

    public func close() {
        if process.isRunning { process.terminate() }
        Self.lock.lock()
        Self.running.removeAll { $0 === process }
        Self.lock.unlock()
    }

    // Every tunnel's ssh is stopped when this process exits, so none are left running after quitting.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Process] = []
    nonisolated(unsafe) private static var registered = false

    private static func register(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running.append(process)
        if !registered {
            registered = true
            atexit {
                SSHTunnel.lock.lock()
                for p in SSHTunnel.running where p.isRunning { kill(p.processIdentifier, SIGTERM) }
                SSHTunnel.lock.unlock()
            }
        }
    }

    deinit { close() }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("Couldn't find a free local port.") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw DatabaseError("Couldn't find a free local port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// ssh's stderr, kept up to 16 KB.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 16_384 { data.append(chunk.prefix(16_384 - data.count)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
