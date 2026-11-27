import Foundation

/// A local port forward through the system `ssh`, so ~/.ssh/config, the agent, jump hosts and
/// known_hosts all work as they do in Terminal. A password or key passphrase, when given, is handed to
/// ssh through a one-off askpass helper (never on the command line); ssh never asks interactively.
public final class SSHTunnel {
    public let localPort: Int
    private let process: Process

    public init(config: ConnectionConfig, secret: String? = nil) throws {
        let secret = secret.flatMap { $0.isEmpty ? nil : $0 }
        // Nothing is run for settings ssh would misread.
        _ = try Self.arguments(config: config, localPort: 1, hasSecret: secret != nil)
        // The local port is picked first and bound by ssh a moment later, so another program can take it in
        // between. ssh then gives up (ExitOnForwardFailure) and the next port is tried.
        var last: DatabaseError?
        for _ in 0..<3 {
            do {
                (process, localPort) = try Self.start(config: config, secret: secret)
                return
            } catch let error as Refused {
                last = error.error
            }
        }
        throw last ?? DatabaseError("The SSH tunnel didn't start.")
    }

    /// ssh couldn't listen on the local port it was given.
    private struct Refused: Error { let error: DatabaseError }

    /// A host or user name ssh can be given: no line breaks or other control characters, no spaces, and not
    /// starting with a hyphen (which ssh would read as an option).
    static func isUsable(_ name: String) -> Bool {
        !name.hasPrefix("-") && !ConnectionConfig.hasControl(name) && !name.contains(where: \.isWhitespace)
    }

    /// The arguments for ssh. Throws for a host or user that could be read as something else.
    static func arguments(config: ConnectionConfig, localPort: Int, hasSecret: Bool, verbose: Bool = false) throws -> [String] {
        func refuse(_ what: String, _ value: String) -> DatabaseError {
            DatabaseError("The \(what) \(value.prefix(60)) can't be used for an SSH tunnel.",
                          detail: "It can't be empty, start with a hyphen, or hold spaces or line breaks.")
        }
        guard !config.sshHost.isEmpty, isUsable(config.sshHost) else { throw refuse("SSH host", config.sshHost) }
        guard isUsable(config.sshUser), !config.sshUser.contains("@") else { throw refuse("SSH user", config.sshUser) }
        guard !config.host.isEmpty, isUsable(config.host), !config.host.contains(","), !config.host.hasPrefix("/") else { throw refuse("host", config.host) }
        guard (1...65535).contains(config.port) else { throw DatabaseError("\(config.port) isn't a port number.", detail: "Ports go from 1 to 65535.") }
        guard (1...65535).contains(config.sshPort) else { throw DatabaseError("\(config.sshPort) isn't a port number.", detail: "Ports go from 1 to 65535.") }
        // An IPv6 address goes in brackets, or its colons would be read as the separators.
        let target = config.host.contains(":") && !config.host.hasPrefix("[") ? "[\(config.host)]" : config.host
        var args = verbose ? ["-v"] : []
        args += [
            "-N", "-T",
            "-o", hasSecret ? "NumberOfPasswordPrompts=1" : "BatchMode=yes",
            // ssh ends when it can't listen on the local port, instead of going on without the forward.
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            // A new server's key is kept; a changed key is refused.
            "-o", "StrictHostKeyChecking=accept-new",
            // Its own connection, never one shared through ~/.ssh/config: the port must be this ssh's to listen on.
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-L", "127.0.0.1:\(localPort):\(target):\(config.port)",
        ]
        if config.sshPort != 22 { args += ["-p", "\(config.sshPort)"] }
        if config.sshUsePassword {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        } else if !config.sshKeyPath.isEmpty {
            args += ["-i", (config.sshKeyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        // After --, what follows is the server and nothing else.
        args += ["--", config.sshUser.isEmpty ? config.sshHost : "\(config.sshUser)@\(config.sshHost)"]
        return args
    }

    private static func start(config: ConnectionConfig, secret: String?) throws -> (Process, Int) {
        let localPort = try freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var askpass: URL?
        if let secret {
            // A tiny script ssh runs to get the secret; the secret itself travels in its environment.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-askpass-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
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
        // MB_SSH_DEBUG=1: ssh explains itself in the error message.
        process.arguments = try arguments(config: config, localPort: localPort, hasSecret: secret != nil,
                                          verbose: ProcessInfo.processInfo.environment["MB_SSH_DEBUG"] != nil)
        let errors = Pipe()
        process.standardError = errors
        // Keep reading ssh's messages so its pipe never fills up during a long session.
        let collected = Collected()
        errors.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        Self.register(process)

        // Wait until this ssh is the one listening on the port, or it gives up. Being able to connect isn't
        // enough: whatever answers on the port gets the database sign-in, so it has to be our own ssh.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                usleep(100_000)
                Self.forget(process)
                let message = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let error = DatabaseError("The SSH tunnel didn't start.", detail: message.isEmpty ? nil : message)
                if message.contains("Address already in use") || message.contains("cannot listen to port") { throw Refused(error: error) }
                throw error
            }
            if isListening(pid: process.processIdentifier, port: localPort) { return (process, localPort) }
            usleep(100_000)
        }
        process.terminate()
        Self.forget(process)
        throw DatabaseError("The SSH tunnel took too long to start.")
    }

    /// True when the process `pid` has a TCP socket listening on `port`.
    static func isListening(pid: Int32, port: Int) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            // The port is kept in network byte order.
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if tcp.tcpsi_state == TSI_S_LISTEN, local == port { return true }
        }
        return false
    }

    public func close() {
        if process.isRunning { process.terminate() }
        Self.forget(process)
    }

    private static func forget(_ process: Process) {
        lock.lock()
        running.removeAll { $0 === process }
        lock.unlock()
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
