import CommonCrypto
import CryptoKit
import Foundation

/// A blocking TCP connection that can switch to TLS part-way, which Postgres and MySQL both need:
/// they ask for TLS in plain text first and only then start the handshake.
final class Socket {
    private let input: InputStream
    private let output: OutputStream
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0
    private var end = 0
    private let host: String
    private(set) var isClosed = false
    /// Set by startTLS(verify: true): the certificate is checked right after the handshake.
    private var needsVerify = false

    /// A host starting with / is a Unix socket path.
    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        self.host = host
        var r: InputStream?
        var w: OutputStream?
        if host.hasPrefix("/") {
            (r, w) = try Self.unixStreams(host)
        } else {
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

    private var anchors: [SecCertificate] = []

    /// Starts TLS on the open connection. The handshake runs on the next read or write.
    func startTLS(_ options: TLSOptions) {
        let verify = options.mode == .verify
        anchors = options.anchors
        // The chain is checked by hand in verifyPeer(), which CFStream doesn't do reliably on its own.
        var settings: [String: Any] = [kCFStreamSSLPeerName as String: host,
                                       kCFStreamSSLValidatesCertificateChain as String: false]
        if let identity = options.identity { settings[kCFStreamSSLCertificates as String] = [identity] }
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        input.setProperty(settings as CFDictionary, forKey: key)
        output.setProperty(settings as CFDictionary, forKey: key)
        needsVerify = verify
    }

    /// Checks the server's certificate against the system trust store and the host name. Call after
    /// the first write following `startTLS`, which runs the handshake, and before sending secrets.
    func verifyPeer() throws {
        let key = Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)
        guard let value = output.property(forKey: key) ?? input.property(forKey: key) else {
            throw DatabaseError("The server's TLS certificate couldn't be read.")
        }
        let trust = value as! SecTrust
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if !anchors.isEmpty {
            // Your own CA: the server's certificate must chain to it.
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if !SecTrustEvaluateWithError(trust, &error) {
            close()
            throw DatabaseError("The server's TLS certificate isn't trusted for \(host).",
                                detail: (error.map { ($0 as Error).localizedDescription } ?? "") +
                                    "\nUse TLS Require to connect without checking the certificate.")
        }
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { throw connectionError(output.streamError) }
            offset += n
        }
        if needsVerify {
            needsVerify = false
            try verifyPeer()
        }
    }

    private func fill() throws {
        if start == end { start = 0; end = 0 }
        if end == buffer.count {
            buffer.removeSubrange(0..<start)
            end -= start
            start = 0
            if end == buffer.count { buffer.append(contentsOf: [UInt8](repeating: 0, count: buffer.count)) }
        }
        let n = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress! + end, maxLength: $0.count - end) }
        if n <= 0 { throw connectionError(input.streamError) }
        end += n
    }

    func readByte() throws -> UInt8 {
        while start == end { try fill() }
        defer { start += 1 }
        return buffer[start]
    }

    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
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
        isClosed = true
        input.close()
        output.close()
    }

    deinit { close() }
}

// MARK: - Bytes

extension Array where Element == UInt8 {
    mutating func appendInt32BE(_ v: Int32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendInt16BE(_ v: Int16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendCString(_ s: String) { append(contentsOf: Array(s.utf8)); append(0) }
    mutating func appendLE(_ v: UInt32, bytes: Int) { for i in 0..<bytes { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

/// Reads values from a received message.
struct ByteReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { pos >= bytes.count }
    var remaining: Int { bytes.count - pos }

    mutating func byte() -> UInt8 { defer { pos += 1 }; return pos < bytes.count ? bytes[pos] : 0 }

    mutating func int16BE() -> Int16 {
        guard pos + 2 <= bytes.count else { pos = bytes.count; return 0 }
        defer { pos += 2 }
        return Int16(bitPattern: UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1]))
    }

    mutating func int32BE() -> Int32 {
        guard pos + 4 <= bytes.count else { pos = bytes.count; return 0 }
        defer { pos += 4 }
        return Int32(bitPattern: UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3]))
    }

    mutating func intLE(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n where pos + i < bytes.count { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += n
        return v
    }

    mutating func cString() -> String {
        let s = pos
        while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
        let str = String(decoding: bytes[s..<pos], as: UTF8.self)
        pos += 1
        return str
    }

    mutating func take(_ n: Int) -> ArraySlice<UInt8> {
        let e = Swift.min(bytes.count, pos + Swift.max(0, n))
        defer { pos = e }
        return bytes[pos..<e]
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

    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        password.withUnsafeBufferPointer { pw in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self), pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(iterations), &out, out.count)
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

/// TLS settings for a connection: the mode, an optional CA to trust, and an optional client certificate.
public struct TLSOptions: @unchecked Sendable {
    public var mode: ConnectionConfig.TLS
    public var anchors: [SecCertificate] = []
    public var identity: SecIdentity?

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
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        for p in alpn { sec_protocol_options_add_tls_application_protocol(sec, p) }
        sec_protocol_options_set_tls_server_name(sec, host)
        if let identity = tls.identity, let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        let mode = tls.mode, anchors = tls.anchors
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            if mode != .verify { return complete(true) }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        let params = NWParameters(tls: options)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: params)
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
