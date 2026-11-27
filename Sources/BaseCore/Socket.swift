import CommonCrypto
import CryptoKit
import Foundation

/// A blocking TCP connection that can switch to TLS part-way, which Postgres and MySQL both need:
/// they ask for TLS in plain text first and only then start the handshake.
final class Socket {
    /// The most one message may ask us to read: a server can't make the app set aside more than this.
    static let maxMessage = 1 << 30

    private let input: InputStream
    private let output: OutputStream
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0
    private var end = 0
    private let host: String
    private(set) var isClosed = false
    private var tls: TLSSession?
    /// Bytes read from the wire that TLS hasn't taken yet.
    private var wire: [UInt8] = []
    private var wirePos = 0

    /// A host starting with / is a Unix socket path.
    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        self.host = host
        var r: InputStream?
        var w: OutputStream?
        if host.hasPrefix("/") {
            (r, w) = try Self.unixStreams(host)
        } else {
            guard (1...65535).contains(port) else { throw DatabaseError("\(port) isn't a port number.", detail: "Ports go from 1 to 65535.") }
            Stream.getStreamsToHost(withName: host, port: port, inputStream: &r, outputStream: &w)
        }
        guard let r, let w else { throw DatabaseError("Couldn't open a connection to \(host):\(port).") }
        input = r
        output = w
        input.open()
        output.open()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let a = input.streamStatus, b = output.streamStatus
            if a == .error || b == .error {
                let message = (input.streamError ?? output.streamError)?.localizedDescription ?? "unknown error"
                throw DatabaseError("Couldn't connect to \(host):\(port).", detail: message)
            }
            if a == .open && b == .open { break }
            if Date() > deadline { close(); throw DatabaseError("Connecting to \(host):\(port) timed out.") }
            usleep(2000)
        }
    }

    private static func unixStreams(_ path: String) throws -> (InputStream?, OutputStream?) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("Couldn't open a socket.") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw DatabaseError("The socket path is too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard ok else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw DatabaseError("Couldn't connect to the socket at \(path).", detail: message)
        }
        var r: Unmanaged<CFReadStream>?
        var w: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, fd, &r, &w)
        let input = r?.takeRetainedValue() as InputStream?
        let output = w?.takeRetainedValue() as OutputStream?
        input?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        output?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        return (input, output)
    }

    /// True once TLS is up: everything read and written from here on is encrypted.
    var isEncrypted: Bool { tls != nil }
    /// True when TLS is up and the server's certificate was checked (TLS Verify).
    private(set) var peerVerified = false

    /// Switches the open connection to TLS. The handshake runs here, and with TLS Verify the server's
    /// certificate is checked here too, so nothing the caller writes afterwards can reach a server that
    /// wasn't checked.
    func startTLS(_ options: TLSOptions) throws {
        // Anything the server sent in the clear after agreeing to TLS would otherwise be read as if it had
        // arrived through TLS, which lets someone on the path put words in the server's mouth.
        guard start == end else {
            close()
            throw DatabaseError("The server sent data before TLS started.", detail: "The connection was closed, because that data can't be trusted.")
        }
        let session = try TLSSession(options: options, peerName: options.peerName ?? host,
                                     read: { [unowned self] count in try self.wireRead(count) },
                                     write: { [unowned self] bytes in try self.wireWrite(bytes) })
        do { try session.handshake() } catch {
            close()
            throw error
        }
        tls = session
        peerVerified = options.mode == .verify
    }

    private func wireWrite(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { throw connectionError(output.streamError) }
            offset += n
        }
    }

    /// Exactly `count` bytes from the wire, for TLS.
    private func wireRead(_ count: Int) throws -> [UInt8] {
        while wire.count - wirePos < count {
            if wirePos > 0 { wire.removeFirst(wirePos); wirePos = 0 }
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            let n = chunk.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { throw connectionError(input.streamError) }
            wire.append(contentsOf: chunk[0..<n])
        }
        defer { wirePos += count }
        return Array(wire[wirePos..<wirePos + count])
    }

    func write(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        if let tls { try tls.write(bytes) } else { try wireWrite(bytes) }
    }

    private func fill() throws {
        if start == end { start = 0; end = 0 }
        if end == buffer.count {
            buffer.removeSubrange(0..<start)
            end -= start
            start = 0
            if end == buffer.count { buffer.append(contentsOf: [UInt8](repeating: 0, count: buffer.count)) }
        }
        let free = buffer.count - end, at = end
        let n: Int
        if let tls {
            n = try buffer.withUnsafeMutableBytes { try tls.read(into: $0.baseAddress! + at, max: free) }
        } else {
            n = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress! + at, maxLength: free) }
        }
        if n <= 0 { throw connectionError(input.streamError) }
        end += n
    }

    func readByte() throws -> UInt8 {
        while start == end { try fill() }
        defer { start += 1 }
        return buffer[start]
    }

    func read(_ count: Int) throws -> [UInt8] {
        // The count comes from the server: a negative or absurd one is a broken reply, not a reason to crash.
        guard count >= 0, count <= Self.maxMessage else { throw DatabaseError.malformedReply("A message of \(count) bytes.") }
        var out = [UInt8]()
        out.reserveCapacity(min(count, 1 << 20))
        while out.count < count {
            if start == end { try fill() }
            let take = min(count - out.count, end - start)
            out.append(contentsOf: buffer[start..<start + take])
            start += take
        }
        return out
    }

    private func connectionError(_ error: Error?) -> DatabaseError {
        if isClosed { return DatabaseError("The connection was closed.") }
        return DatabaseError("The connection was lost.", detail: error?.localizedDescription)
    }

    func close() {
        guard !isClosed else { return }
        tls?.close()
        isClosed = true
        input.close()
        output.close()
    }

    deinit { close() }
}

// MARK: - TLS

/// Checking a server's certificate, the same way for every transport.
enum TLSTrust {
    /// Nil when the certificate is valid for `host` and chains to a root this Mac trusts, or to one of
    /// `anchors` when you gave your own CA. Otherwise, why not.
    static func problem(_ trust: SecTrust, host: String, anchors: [SecCertificate]) -> String? {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { ($0 as Error).localizedDescription } ?? "The certificate couldn't be checked."
    }

    static func error(host: String, reason: String) -> DatabaseError {
        DatabaseError("The server's TLS certificate isn't trusted for \(host).",
                      detail: reason + "\nIf the server has its own certificate authority, choose its CA file. To connect without checking the certificate, set TLS to Require.")
    }
}

/// TLS over reads and writes the caller supplies, for protocols that start TLS part-way through a plain
/// connection (Postgres, MySQL) or carry the handshake in their own packets (TDS 7). The handshake stops
/// when the server has shown its certificate, so it is checked before anything of ours is sent.
/// This is SecureTransport: deprecated, but still in macOS, and the only system TLS that runs over
/// something other than a socket it owns.
final class TLSSession {
    private let context: SSLContext
    private let options: TLSOptions
    private let peerName: String
    private let readWire: (Int) throws -> [UInt8]
    private let writeWire: ([UInt8]) throws -> Void
    /// What a read or write underneath failed with, to report instead of a bare TLS status.
    private var failure: Error?
    private var closed = false

    /// `read` returns exactly the number of bytes asked for, or throws.
    init(options: TLSOptions, peerName: String, read: @escaping (Int) throws -> [UInt8], write: @escaping ([UInt8]) throws -> Void) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else { throw DatabaseError("TLS couldn't start.") }
        self.context = context
        self.options = options
        self.peerName = peerName
        readWire = read
        writeWire = write
        SSLSetIOFuncs(context, { connection, data, length in
            let me = Unmanaged<TLSSession>.fromOpaque(connection).takeUnretainedValue()
            let wanted = length.pointee
            guard wanted > 0 else { return errSecSuccess }
            do {
                let bytes = try me.readWire(wanted)
                guard bytes.count == wanted else { length.pointee = 0; return errSSLClosedAbort }
                bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: wanted) }
                return errSecSuccess
            } catch {
                me.failure = error
                length.pointee = 0
                return errSSLClosedAbort
            }
        }, { connection, data, length in
            let me = Unmanaged<TLSSession>.fromOpaque(connection).takeUnretainedValue()
            do {
                try me.writeWire(Array(UnsafeRawBufferPointer(start: data, count: length.pointee)))
                return errSecSuccess
            } catch {
                me.failure = error
                length.pointee = 0
                return errSSLClosedAbort
            }
        })
        SSLSetConnection(context, Unmanaged.passUnretained(self).toOpaque())
        // The name goes out in the handshake (SNI), which is for names only.
        if !HostScope.isAddress(peerName) { SSLSetPeerDomainName(context, peerName, peerName.utf8.count) }
        // Stop at the server's certificate instead of letting SecureTransport judge it: we do that ourselves,
        // against your own CA when there is one.
        SSLSetSessionOption(context, .breakOnServerAuth, true)
        if let identity = options.identity { SSLSetCertificate(context, [identity] as CFArray) }
    }

    /// Runs the handshake. With TLS Verify, throws unless the server's certificate is valid for the name.
    func handshake() throws {
        var checked = false
        while true {
            let status = SSLHandshake(context)
            if status == errSecSuccess { break }
            if status == errSSLPeerAuthCompleted {
                try checkPeer()
                checked = true
                continue
            }
            if status == errSSLWouldBlock { continue }
            if let failure { throw failure }
            throw DatabaseError("The TLS handshake failed.", detail: Self.describe(status))
        }
        // A handshake that never showed a certificate must not count as checked.
        if !checked { try checkPeer() }
    }

    private func checkPeer() throws {
        guard options.mode == .verify else { return }
        var trust: SecTrust?
        SSLCopyPeerTrust(context, &trust)
        guard let trust else { throw DatabaseError("The server's TLS certificate couldn't be read.") }
        if let reason = TLSTrust.problem(trust, host: peerName, anchors: options.anchors) { throw TLSTrust.error(host: peerName, reason: reason) }
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            var written = 0
            let status = bytes.withUnsafeBytes { SSLWrite(context, $0.baseAddress! + offset, bytes.count - offset, &written) }
            offset += written
            if status == errSecSuccess || (status == errSSLWouldBlock && written > 0) { continue }
            if let failure { throw failure }
            throw DatabaseError("The connection was lost.", detail: Self.describe(status))
        }
    }

    /// Reads at least one byte, at most `max`.
    func read(into pointer: UnsafeMutableRawPointer, max: Int) throws -> Int {
        while true {
            var got = 0
            let status = SSLRead(context, pointer, max, &got)
            if got > 0 { return got }
            if status == errSecSuccess || status == errSSLWouldBlock { continue }
            if let failure { throw failure }
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify { throw DatabaseError("The connection was closed.") }
            throw DatabaseError("The connection was lost.", detail: Self.describe(status))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        SSLClose(context)
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "TLS error \(status)"
    }
}

// MARK: - Bytes

extension Array where Element == UInt8 {
    mutating func appendInt32BE(_ v: Int32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendInt16BE(_ v: Int16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendCString(_ s: String) { append(contentsOf: Array(s.utf8)); append(0) }
    mutating func appendLE(_ v: UInt32, bytes: Int) { for i in 0..<bytes { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

/// Reads values from a received message. Reading past the end gives zeros and empty slices instead of
/// stopping the app: what a server sends is never trusted to be well-formed.
struct ByteReader {
    let bytes: [UInt8]
    /// Always within the message, whatever it is set to.
    var pos = 0 { didSet { if pos < 0 { pos = 0 } else if pos > bytes.count { pos = bytes.count } } }

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { pos >= bytes.count }
    var remaining: Int { bytes.count - pos }

    mutating func byte() -> UInt8 {
        guard pos < bytes.count else { return 0 }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func int16BE() -> Int16 {
        guard remaining >= 2 else { pos = bytes.count; return 0 }
        defer { pos += 2 }
        return Int16(bitPattern: UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1]))
    }

    mutating func int32BE() -> Int32 {
        guard remaining >= 4 else { pos = bytes.count; return 0 }
        defer { pos += 4 }
        return Int32(bitPattern: UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3]))
    }

    mutating func intLE(_ n: Int) -> UInt64 {
        let n = Swift.max(0, Swift.min(n, 8))
        var v: UInt64 = 0
        for i in 0..<n where pos + i < bytes.count { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += Swift.min(n, remaining)
        return v
    }

    mutating func cString() -> String {
        let s = pos
        var e = pos
        while e < bytes.count && bytes[e] != 0 { e += 1 }
        pos = e + 1
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }

    mutating func take(_ n: Int) -> ArraySlice<UInt8> {
        let n = Swift.max(0, Swift.min(n, remaining))
        defer { pos += n }
        return bytes[pos..<pos + n]
    }

    mutating func rest() -> ArraySlice<UInt8> { take(remaining) }
}

// MARK: - Crypto

enum Crypto {
    static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }
    static func sha1(_ data: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }

    static func md5Hex(_ data: [UInt8]) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// The most PBKDF2 rounds a server may ask for. Postgres and MongoDB use a few thousand; without a limit,
    /// a server could keep the app hashing for hours.
    static let maxPBKDF2Rounds = 10_000_000

    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int) throws -> [UInt8] {
        guard (1...maxPBKDF2Rounds).contains(iterations) else {
            throw DatabaseError.malformedReply("The sign-in asks for \(iterations) rounds of password hashing.")
        }
        var out = [UInt8](repeating: 0, count: 32)
        var status = Int32(kCCParamError)
        if !password.isEmpty {
            status = password.withUnsafeBytes { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.bindMemory(to: CChar.self).baseAddress, pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(iterations), &out, out.count)
            }
        }
        if status == kCCSuccess { return out }
        // CommonCrypto wants a password; an empty one is still a valid key for the same sums.
        let key = SymmetricKey(data: password)
        var u = Array(HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        out = u
        for _ in 1..<iterations {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
            out = xor(out, u)
        }
        return out
    }

    static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 ^ $1 } }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return bytes
    }
}

/// Just enough DER to find a key inside its wrapper. Every length is checked against the data, so a
/// malformed key is refused instead of read past its end.
struct DER {
    let bytes: [UInt8]
    private(set) var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The content of the element at the cursor, when it has this tag. Leaves the cursor at the content's start.
    private mutating func content(_ tag: UInt8) -> Range<Int>? {
        guard pos + 1 < bytes.count, bytes[pos] == tag else { return nil }
        var i = pos + 1
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), i + count <= bytes.count else { return nil }
            length = bytes[i..<i + count].reduce(0) { $0 << 8 | Int($1) }
            i += count
        }
        guard length <= bytes.count - i else { return nil }
        pos = i
        return i..<i + length
    }

    /// Steps into a SEQUENCE (or any element that holds others).
    mutating func enter(_ tag: UInt8) -> Bool { content(tag) != nil }

    /// Steps over an element and returns where its content is.
    mutating func element(_ tag: UInt8) -> Range<Int>? {
        guard let range = content(tag) else { return nil }
        pos = range.upperBound
        return range
    }
}

/// TLS settings for a connection: the mode, an optional CA to trust, and an optional client certificate.
public struct TLSOptions: @unchecked Sendable {
    public var mode: ConnectionConfig.TLS
    public var anchors: [SecCertificate] = []
    public var identity: SecIdentity?
    /// The name the certificate must be valid for, when that isn't the host the connection is made to:
    /// through an SSH tunnel the connection goes to 127.0.0.1, but the certificate is the server's.
    public var peerName: String?

    public init(_ mode: ConnectionConfig.TLS, anchors: [SecCertificate] = [], identity: SecIdentity? = nil) {
        self.mode = mode
        self.anchors = anchors
        self.identity = identity
    }

    /// Reads the CA file (PEM with one or more certificates, or DER) and the client .p12.
    public static func load(_ config: ConnectionConfig, certificatePassword: String?) throws -> TLSOptions {
        var options = TLSOptions(config.tls)
        let ca = (config.caFile as NSString).expandingTildeInPath
        if !config.caFile.isEmpty {
            guard let data = FileManager.default.contents(atPath: ca) else { throw DatabaseError("The CA file can't be read.", detail: ca) }
            options.anchors = certificates(data)
            if options.anchors.isEmpty { throw DatabaseError("The CA file has no certificates in it.", detail: ca) }
        }
        let p12 = (config.clientCertFile as NSString).expandingTildeInPath
        if !config.clientCertFile.isEmpty {
            guard let data = FileManager.default.contents(atPath: p12) else { throw DatabaseError("The client certificate can't be read.", detail: p12) }
            var items: CFArray?
            let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: certificatePassword ?? ""] as CFDictionary, &items)
            guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
                  let identity = first[kSecImportItemIdentity as String] else {
                throw DatabaseError("The client certificate couldn't be opened.",
                                    detail: status == errSecAuthFailed ? "The .p12 password is wrong." : "Make one with: openssl pkcs12 -export -in client.crt -inkey client.key -out client.p12")
            }
            options.identity = (identity as! SecIdentity)
        }
        return options
    }

    static func certificates(_ data: Data) -> [SecCertificate] {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("-----BEGIN CERTIFICATE-----") else {
            return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
        }
        return text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { part in
            let body = part.components(separatedBy: "-----END CERTIFICATE-----")[0].filter { !$0.isWhitespace }
            return Data(base64Encoded: body).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
    }
}

// MARK: - Network.framework transport (TLS 1.3, ALPN)

import Network

/// What a driver reads and writes through: a CFStream socket, or a Network.framework connection.
protocol ByteStream: AnyObject {
    func write(_ bytes: [UInt8]) throws
    func read(_ count: Int) throws -> [UInt8]
    func readByte() throws -> UInt8
    func close()
}

extension Socket: ByteStream {}

/// A TLS connection through Network.framework, for engines that need TLS 1.3 or ALPN from the first byte
/// (SQL Server's TDS 8, "strict" encryption).
final class NWStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "gg.maben.base.nw")
    private var buffer: [UInt8] = []
    private var closed = false

    init(host: String, port: Int, tls: TLSOptions, alpn: [String], timeout: TimeInterval = 15) throws {
        guard let number = UInt16(exactly: port), number > 0, let nwPort = NWEndpoint.Port(rawValue: number) else {
            throw DatabaseError("\(port) isn't a port number.", detail: "Ports go from 1 to 65535.")
        }
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        for p in alpn { sec_protocol_options_add_tls_application_protocol(sec, p) }
        let name = tls.peerName ?? host
        sec_protocol_options_set_tls_server_name(sec, name)
        if let identity = tls.identity, let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        let mode = tls.mode, anchors = tls.anchors
        // Runs during the handshake, so a refused certificate ends the connection before anything is sent.
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            if mode != .verify { return complete(true) }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            complete(TLSTrust.problem(trust, host: name, anchors: anchors) == nil)
        }, queue)
        let params = NWParameters(tls: options)
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e), .waiting(let e): failure = e; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw DatabaseError("Connecting to \(host):\(port) timed out.")
        }
        if let failure {
            connection.cancel()
            throw DatabaseError("Couldn't make a TLS connection to \(host):\(port).", detail: failure.localizedDescription)
        }
        connection.stateUpdateHandler = nil
    }

    func write(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: Data(bytes), completion: .contentProcessed { e in failure = e; done.signal() })
        done.wait()
        if let failure { throw DatabaseError("The connection was lost.", detail: failure.localizedDescription) }
    }

    private func fill() throws {
        let done = DispatchSemaphore(value: 0)
        var chunk: Data?
        var failure: Error?
        var complete = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            chunk = data; failure = error; complete = isComplete; done.signal()
        }
        done.wait()
        if let chunk, !chunk.isEmpty { buffer += chunk; return }
        if let failure { throw DatabaseError("The connection was lost.", detail: failure.localizedDescription) }
        if complete || closed { throw DatabaseError("The connection was closed.") }
    }

    func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= Socket.maxMessage else { throw DatabaseError.malformedReply("A message of \(count) bytes.") }
        while buffer.count < count { try fill() }
        let out = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    func readByte() throws -> UInt8 { try read(1)[0] }

    func close() {
        closed = true
        connection.cancel()
    }
}
