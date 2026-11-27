@testable import BaseCore
import XCTest

/// A server on 127.0.0.1 that takes one connection and does what `script` says: for showing the drivers
/// something no real server would send, and for seeing exactly what they send.
final class FakeServer {
    final class Connection {
        fileprivate let fd: Int32
        private let lock = NSLock()
        private var seen: [UInt8] = []
        fileprivate init(fd: Int32) { self.fd = fd }

        /// Everything the client has sent so far.
        var received: [UInt8] { lock.lock(); defer { lock.unlock() }; return seen }

        /// Reads until `count` bytes have arrived, the client closes, or `timeout` passes.
        @discardableResult
        func read(_ count: Int, timeout: TimeInterval = 3) -> [UInt8] {
            var out: [UInt8] = []
            let deadline = Date().addingTimeInterval(timeout)
            while out.count < count, Date() < deadline {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 50) > 0 else { continue }
                var chunk = [UInt8](repeating: 0, count: count - out.count)
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                out += chunk[0..<n]
            }
            lock.lock(); seen += out; lock.unlock()
            return out
        }

        /// Whatever arrives within `timeout`.
        @discardableResult
        func readAvailable(_ timeout: TimeInterval = 0.4) -> [UInt8] { read(1 << 20, timeout: timeout) }

        func write(_ bytes: [UInt8]) {
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                offset += n
            }
        }
    }

    let port: Int
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var connection: Connection?

    init(_ script: @escaping (Connection) -> Void) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, len) == 0 && getsockname(listener, $0, &len) == 0 }
        }
        guard ok, listen(listener, 4) == 0 else { throw DatabaseError("The test server couldn't listen.") }
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { [self] in
            var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 10_000) > 0 {
                let fd = accept(listener, nil, nil)
                if fd >= 0 {
                    var on: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    let c = Connection(fd: fd)
                    lock.lock(); connection = c; lock.unlock()
                    script(c)
                    close(fd)
                }
            }
            close(listener)
            finished.signal()
        }
    }

    /// What the client sent, once the script has run to its end.
    func received(timeout: TimeInterval = 10) -> [UInt8] {
        _ = finished.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return connection?.received ?? []
    }
}

private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
    let n = Array(needle.utf8)
    guard !n.isEmpty, haystack.count >= n.count else { return false }
    return (0...(haystack.count - n.count)).contains { Array(haystack[$0..<$0 + n.count]) == n }
}

/// Runs `work` off the test's thread and fails instead of hanging when a driver waits for ever.
private func within<T>(_ seconds: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ work: @escaping () throws -> T) -> Result<T, Error>? {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    DispatchQueue.global().async {
        result = Result { try work() }
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds) == .success else {
        XCTFail("still waiting after \(seconds) seconds", file: file, line: line)
        return nil
    }
    return result
}

private func message(_ result: Result<some Any, Error>?) -> String {
    guard case .failure(let error)? = result else { return "" }
    return (error as? DatabaseError).map { [$0.message, $0.detail ?? ""].joined(separator: " ") } ?? "\(error)"
}

final class WireTests: XCTestCase {
    private let secret = "S3CRET-pass-9f2c"

    /// This Mac under a name that isn't one of the names for "nearby": the number 127.0.0.1 is, written as
    /// one integer. It lets a test stand in for a server out on the internet.
    private func farHost(port: Int) throws -> String {
        let host = "2130706433"
        XCTAssertFalse(HostScope.isLocal(host))
        guard let probe = try? Socket(host: host, port: port, timeout: 3) else { throw XCTSkip("this Mac doesn't resolve \(host) to itself") }
        probe.close()
        return host
    }

    // MARK: Plain text where TLS was expected

    func testPostgresPlainBytesAfterTheTLSAnswerEndTheConnection() throws {
        let server = try FakeServer { c in
            c.read(8)
            // "Yes to TLS", and in the same breath bytes that aren't TLS: someone on the path speaking for the server.
            c.write(Array("S".utf8) + Array("R\0\0\0\u{8}\0\0\0\0".utf8))
            c.readAvailable()
        }
        let port = server.port, secret = secret
        let result = within { try PostgresDriver(host: "127.0.0.1", port: port, user: "u", password: secret, database: "d", tls: TLSOptions(.require)) }
        XCTAssertTrue(message(result).contains("sent data before TLS started"), message(result))
        XCTAssertFalse(contains(server.received(), "user"), "no startup message went out")
    }

    func testMySQLPlainBytesAfterTheGreetingEndTheConnection() throws {
        let greeting = Self.mysqlGreeting(plugin: "caching_sha2_password", ssl: true)
        let server = try FakeServer { c in
            c.write(greeting + [7, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0])   // an OK packet nobody asked for
            c.readAvailable()
        }
        let port = server.port, secret = secret
        let result = within { try MySQLDriver(host: "127.0.0.1", port: port, user: "root", password: secret, database: "", tls: TLSOptions(.require)) }
        XCTAssertTrue(message(result).contains("sent data before TLS started"), message(result))
        XCTAssertFalse(contains(server.received(), "root"), "the user name never went out")
    }

    func testPostgresWithoutTLSIsOnlyUsedNearby() throws {
        func attempt(host: String, mode: ConnectionConfig.TLS) throws -> (String, [UInt8]) {
            let server = try FakeServer { c in
                c.read(8)
                c.write(Array("N".utf8))   // no TLS here
                c.readAvailable()
            }
            let port = server.port
            let result = within { try PostgresDriver(host: host, port: port, user: "appuser", password: "pw", database: "d", tls: TLSOptions(mode)) }
            return (message(result), server.received())
        }
        let far = try farHost(port: try FakeServer { _ in }.port)
        var (error, sent) = try attempt(host: far, mode: .prefer)
        XCTAssertTrue(error.contains("doesn't offer TLS") && error.contains("set TLS to Off"), error)
        XCTAssertFalse(contains(sent, "appuser"), "nothing after the question went out")
        (error, sent) = try attempt(host: far, mode: .require)
        XCTAssertTrue(error.contains("doesn't accept TLS"), error)
        XCTAssertFalse(contains(sent, "appuser"))
        (error, sent) = try attempt(host: "127.0.0.1", mode: .require)
        XCTAssertFalse(contains(sent, "appuser"), "Require never goes on plain, nearby either")
        // Nearby, Prefer goes on as before.
        (_, sent) = try attempt(host: "127.0.0.1", mode: .prefer)
        XCTAssertTrue(contains(sent, "appuser"))
    }

    // MARK: MySQL: the password itself

    private static func mysqlGreeting(plugin: String, ssl: Bool) -> [UInt8] {
        var p: [UInt8] = [10] + Array("8.4.0".utf8) + [0]
        p += [1, 0, 0, 0]                                   // connection id
        p += Array("abcdefgh".utf8) + [0]                   // challenge, part 1
        let caps: UInt32 = 0x0200 | 0x8000 | 0x0008_0000 | 0x0020_0000 | 0x0001 | 0x0008 | (ssl ? 0x0800 : 0)
        p += [UInt8(caps & 0xFF), UInt8((caps >> 8) & 0xFF), 45, 2, 0, UInt8((caps >> 16) & 0xFF), UInt8((caps >> 24) & 0xFF), 21]
        p += [UInt8](repeating: 0, count: 10)
        p += Array("ijklmnopqrst".utf8) + [0]               // challenge, part 2
        p += Array(plugin.utf8) + [0]
        return [UInt8(p.count & 0xFF), UInt8(p.count >> 8), 0, 0] + p
    }

    func testMySQLNeverHandsThePasswordToAServerThatWasntChecked() throws {
        let secret = secret
        func attempt(host: String, switchLater: Bool) throws -> (String, [UInt8]) {
            let server = try FakeServer { c in
                c.write(Self.mysqlGreeting(plugin: switchLater ? "mysql_native_password" : "mysql_clear_password", ssl: false))
                c.readAvailable()
                if switchLater {
                    let body: [UInt8] = [0xFE] + Array("mysql_clear_password".utf8) + [0]
                    c.write([UInt8(body.count), 0, 0, 2] + body)
                    c.readAvailable()
                }
            }
            let port = server.port
            let result = within { try MySQLDriver(host: host, port: port, user: "root", password: secret, database: "", tls: TLSOptions(.off)) }
            return (message(result), server.received())
        }
        let far = try farHost(port: try FakeServer { _ in }.port)
        for switchLater in [false, true] {
            let (error, sent) = try attempt(host: far, switchLater: switchLater)
            XCTAssertTrue(error.contains("asks for the password as plain text"), error)
            XCTAssertFalse(contains(sent, secret), "switch later: \(switchLater)")
        }
        // Nearby it is sent, as before (a local server with that plugin).
        XCTAssertTrue(contains(try attempt(host: "127.0.0.1", switchLater: false).1, secret))
    }

    // MARK: Replies that aren't the protocol

    func testRedisRepliesCantAskForMoreThanTheyAre() throws {
        let replies: [(String, [UInt8])] = [
            ("a value of 99 terabytes", Array("$99999999999999\r\n".utf8)),
            ("a list of two billion items", Array("*2000000000\r\n".utf8)),
            ("lists nested 200 deep", Array(String(repeating: "*1\r\n", count: 200).utf8)),
            ("a line that never ends", [UInt8](repeating: 0x61, count: 3 << 20)),
            ("a kind of reply that doesn't exist", Array("?what\r\n".utf8)),
            ("a negative length that isn't -1", Array("$-7\r\n+OK\r\n".utf8)),
        ]
        for (what, bytes) in replies {
            let server = try FakeServer { c in
                c.readAvailable(0.2)
                c.write(bytes)
                c.readAvailable(0.2)
            }
            let port = server.port
            let result = within { try RedisDriver(host: "127.0.0.1", port: port, user: "", password: "", database: "", tls: TLSOptions(.off)) }
            guard case .failure? = result else { XCTFail("\(what): expected an error"); continue }
        }
    }

    func testPostgresMessagesCantClaimAnImpossibleLength() throws {
        for length: [UInt8] in [[0xFF, 0xFF, 0xFF, 0xFF], [0x7F, 0xFF, 0xFF, 0xFF], [0, 0, 0, 0], [0x80, 0, 0, 0]] {
            let server = try FakeServer { c in
                c.readAvailable(0.2)
                c.write(Array("R".utf8) + length)
                c.readAvailable(0.2)
            }
            let port = server.port
            let result = within { try PostgresDriver(host: "127.0.0.1", port: port, user: "u", password: "p", database: "d", tls: TLSOptions(.off)) }
            XCTAssertTrue(message(result).contains("doesn't understand"), "\(length): \(message(result))")
        }
    }

    /// Every driver, shown bytes that mean nothing: each must give up with an error. Before this was looked
    /// at, replies like these stopped the app (an index past the end, a length that doesn't fit, a count
    /// taken at its word).
    func testNoDriverStopsTheAppOnNoise() throws {
        var blobs: [[UInt8]] = [[UInt8](repeating: 0xFF, count: 4096), [UInt8](repeating: 0, count: 4096), [], [0x80], Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)]
        for seed in 1...12 {
            var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
            blobs.append((0..<(seed % 3 == 0 ? 64 : 16_384)).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 33)
            })
        }
        let drivers: [(String, (Int) throws -> Driver)] = [
            ("Postgres", { try PostgresDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", database: "d", tls: TLSOptions(.off)) }),
            ("MySQL", { try MySQLDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", database: "d", tls: TLSOptions(.off)) }),
            ("Redis", { try RedisDriver(host: "127.0.0.1", port: $0, user: "", password: "p", database: "0", tls: TLSOptions(.off)) }),
            ("MongoDB", { try MongoDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", database: "d", tls: TLSOptions(.off), options: [:]) }),
            ("Cassandra", { try CassandraDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", keyspace: "k", tls: TLSOptions(.off)) }),
            ("SQL Server", { try SQLServerDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", database: "d", tls: TLSOptions(.off)) }),
            ("SQL Server with TLS", { try SQLServerDriver(host: "127.0.0.1", port: $0, user: "u", password: "p", database: "d", tls: TLSOptions(.prefer)) }),
        ]
        let cases = drivers.flatMap { driver in blobs.indices.map { (driver.0, driver.1, $0) } }
        let lock = NSLock()
        var survived: [String] = []
        DispatchQueue.concurrentPerform(iterations: cases.count) { n in
            let (name, open, i) = cases[n]
            guard let server = try? FakeServer({ c in
                c.readAvailable(0.05)
                c.write(blobs[i])
                // Keep answering with the same noise for as long as the driver keeps asking.
                for _ in 0..<6 where !c.readAvailable(0.05).isEmpty { c.write(blobs[i]) }
            }) else { return }
            let port = server.port
            let result = within { try open(port) }
            if case .success? = result {
                lock.lock(); survived.append("\(name), reply \(i)"); lock.unlock()
            }
        }
        XCTAssertEqual(survived, [], "these took noise for a sign-in")
    }

    func testHTTPEnginesGiveUpOnAnswersThatArentTheirs() throws {
        let bodies = ["", "not json", "{\"results\": 5}", "[[[[", "{\"results\":[{\"type\":\"ok\",\"response\":{\"type\":\"execute\",\"result\":{\"cols\":[{\"name\":\"a\"}],\"rows\":[[],[{\"type\":\"text\"}]]}}}]}",
                      "a\tb\n", "a\tb\nInt8\n1\t2\t3\n\n"]
        for body in bodies {
            for kind in ["libsql", "clickhouse"] {
                let server = try FakeServer { c in
                    c.readAvailable(0.2)
                    c.write(Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
                }
                let port = server.port
                let result = within { () -> [Row] in
                    let driver: Driver = kind == "libsql" ? try LibSQLDriver(host: "127.0.0.1", port: port, token: "", tls: TLSOptions(.off))
                                                         : try ClickHouseDriver(host: "127.0.0.1", port: port, user: "u", password: "p", database: "d", tls: TLSOptions(.off))
                    return try driver.rows("SELECT 1")
                }
                XCTAssertNotNil(result, "\(kind): \(body)")   // an error or an answer; what matters is that it came back
            }
        }
    }
}

final class ParserTests: XCTestCase {
    func testReadingPastTheEndOfAMessageGivesZeros() {
        var r = ByteReader([1, 2, 3])
        XCTAssertEqual(r.int16BE(), 0x0102)
        XCTAssertEqual(r.int32BE(), 0)
        XCTAssertTrue(r.atEnd)
        XCTAssertEqual(r.byte(), 0)
        XCTAssertEqual(r.intLE(8), 0)
        XCTAssertEqual(Array(r.take(10)), [])
        XCTAssertEqual(r.cString(), "")
        r.pos = -5
        XCTAssertEqual(r.pos, 0)
        XCTAssertEqual(Array(r.take(-1)), [])
        XCTAssertEqual(Array(r.take(Int.max)), [1, 2, 3])
        r.pos = 99
        XCTAssertEqual(r.pos, 3)
        var s = ByteReader([0x41, 0x42])
        XCTAssertEqual(s.cString(), "AB", "a string without its ending zero stops at the end of the message")
        XCTAssertEqual(s.intLE(99), 0)
    }

    func testResultsAlwaysLeaveADriverAsARectangle() {
        var r = QueryResult(columns: [ResultColumn(name: "a", typeName: ""), ResultColumn(name: "b", typeName: "")], rows: [["1"], ["1", "2", "3"], [], ["x", nil]])
        r.squareUp()
        XCTAssertEqual(r.rows, [["1", nil], ["1", "2"], [nil, nil], ["x", nil]])
        let row = Row(["only"])
        XCTAssertEqual(row[0], "only")
        XCTAssertNil(row[1])
        XCTAssertNil(row[-1])
        XCTAssertNil(row[1000])
    }

    func testAServerCantKeepTheAppHashing() {
        XCTAssertThrowsError(try Crypto.pbkdf2SHA256(password: [1], salt: [2], iterations: 2_000_000_000))
        XCTAssertThrowsError(try Crypto.pbkdf2SHA256(password: [1], salt: [2], iterations: 0))
        XCTAssertThrowsError(try Crypto.pbkdf2SHA256(password: [1], salt: [2], iterations: -1))
        XCTAssertThrowsError(try MongoDriver.pbkdf2SHA1([1], salt: [2], iterations: Int.max))
        XCTAssertEqual(try Crypto.pbkdf2SHA256(password: Array("password".utf8), salt: Array("salt".utf8), iterations: 2).map { String(format: "%02x", $0) }.joined(),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(try Crypto.pbkdf2SHA256(password: [], salt: Array("salt".utf8), iterations: 2).count, 32)
    }

    func testKeysWithLengthsThatDontFitAreRefused() {
        XCTAssertNil(MySQLDriver.pkcs1Range(in: []))
        XCTAssertNil(MySQLDriver.pkcs1Range(in: [0x30]))
        XCTAssertNil(MySQLDriver.pkcs1Range(in: [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x30, 0x00]))
        XCTAssertNil(MySQLDriver.pkcs1Range(in: [0x30, 0x06, 0x30, 0x00, 0x03, 0x7F, 0x00, 0x01]), "a BIT STRING longer than the key")
        XCTAssertNil(MySQLDriver.pkcs1Range(in: [0x30, 0x05, 0x30, 0x00, 0x03, 0x01, 0x00]), "nothing after the unused-bits byte")
        XCTAssertEqual(MySQLDriver.pkcs1Range(in: [0x30, 0x07, 0x30, 0x00, 0x03, 0x03, 0x00, 0xAA, 0xBB]), 7..<9)
        // Not a PKCS#8 key: handed on as it is, for Security to refuse.
        XCTAssertEqual(JWT.pkcs1([0x30, 0x82, 0xFF]), [0x30, 0x82, 0xFF])
        XCTAssertEqual(JWT.pkcs1([]), [])
    }

    func testBSONThatIsCutShortOrNestedWithoutEndIsRefused() {
        XCTAssertThrowsError(try BSON.decode([]))
        XCTAssertThrowsError(try BSON.decode([5, 0, 0]))
        XCTAssertThrowsError(try BSON.decode([0xFF, 0xFF, 0xFF, 0x7F, 0]), "a length past the end")
        XCTAssertThrowsError(try BSON.decode([0xFF, 0xFF, 0xFF, 0xFF, 0]), "a negative length")
        XCTAssertThrowsError(try BSON.decode([5, 0, 0, 0, 0], at: 3))
        XCTAssertThrowsError(try BSON.decode([5, 0, 0, 0, 0], at: -1))
        XCTAssertNoThrow(try BSON.decode([5, 0, 0, 0, 0]))
        // { a: "…" } where the string says it is two gigabytes long.
        XCTAssertNoThrow(try BSON.decode([14, 0, 0, 0, 0x02, 0x61, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0x78, 0, 0]))
        // A document inside a document inside a document, 1,000 deep.
        var nested: [UInt8] = [5, 0, 0, 0, 0]
        for _ in 0..<1000 {
            let n = UInt32(nested.count + 8)
            nested = [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24), 0x03, 0x61, 0] + nested + [0]
        }
        XCTAssertThrowsError(try BSON.decode(nested))
        XCTAssertThrowsError(try MongoText.parse(String(repeating: "[", count: 5000)))
        XCTAssertThrowsError(try MongoText.parse(String(repeating: "{a:", count: 5000)))
    }

    func testBSONNumbersThatDontFitDontStopTheApp() {
        XCTAssertNil(BSON.double(.nan).int)
        XCTAssertNil(BSON.double(.infinity).int)
        XCTAssertNil(BSON.double(1e300).int)
        XCTAssertEqual(BSON.double(7.9).int, 7)
        XCTAssertEqual(BSON.decimalString(Data()), BSON.decimalString(Data(repeating: 0, count: 16)), "a decimal that was cut short reads as zeros, not past its end")
        XCTAssertFalse(BSON.decimalString(Data([1, 2, 3])).isEmpty)
        XCTAssertThrowsError(try MongoText.parse("NumberInt(99999999999)"))
        XCTAssertThrowsError(try MongoText.parse("BinData(999, \"AA==\")"))
        XCTAssertThrowsError(try MongoText.parse("Timestamp(-1, 0)"))
    }

    func testReadingMoreThanAMessageMayHoldIsRefused() throws {
        let server = try FakeServer { c in c.readAvailable(0.3) }
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        defer { socket.close() }
        XCTAssertThrowsError(try socket.read(-1))
        XCTAssertThrowsError(try socket.read(Socket.maxMessage + 1))
        XCTAssertThrowsError(try Socket(host: "127.0.0.1", port: 0))
        XCTAssertThrowsError(try Socket(host: "127.0.0.1", port: 70_000))
    }
}

/// TLS against a real TLS server: the `openssl s_server` that comes with macOS, with a certificate made for
/// the test. It prints what it receives through TLS, which is how the tests see what reached it.
final class TLSWireTests: XCTestCase {
    private var dir: URL!
    private var server: Process?
    private var port = 0
    private let output = Output()
    private let secret = "S3CRET-pass-7a1e"

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Starts the server. `www`: it answers HTTP requests with a page instead of printing what it gets.
    private func start(www: Bool = false) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("no /usr/bin/openssl") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-tls-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("req.cnf").path, key = dir.appendingPathComponent("key.pem").path, cert = dir.appendingPathComponent("cert.pem").path
        try """
            [req]
            distinguished_name = dn
            x509_extensions = ext
            prompt = no
            [dn]
            CN = localhost
            [ext]
            subjectAltName = DNS:localhost
            extendedKeyUsage = serverAuth
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature,keyCertSign
            """.write(toFile: config, atomically: true, encoding: .utf8)
        guard run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "30", "-keyout", key, "-out", cert, "-config", config]) else {
            throw XCTSkip("openssl couldn't make a certificate")
        }
        port = try SSHTunnel.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["s_server", "-accept", "\(port)", "-cert", cert, "-key", key] + (www ? ["-www"] : ["-quiet"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = Pipe()   // kept open: the server stops when its input ends
        let output = output
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        try p.run()
        server = p
        let deadline = Date().addingTimeInterval(5)
        while !SSHTunnel.canConnect(port: port) {
            guard Date() < deadline, p.isRunning else { throw XCTSkip("openssl s_server didn't start") }
            usleep(50_000)
        }
        usleep(100_000)
    }

    override func tearDown() {
        server?.terminate()
        server = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func ownCA() throws -> [SecCertificate] {
        let anchors = TLSOptions.certificates(try Data(contentsOf: dir.appendingPathComponent("cert.pem")))
        XCTAssertEqual(anchors.count, 1)
        return anchors
    }

    private func arrives(_ text: String, within seconds: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if output.text.contains(text) { return true }
            usleep(50_000)
        }
        return false
    }

    /// The finding itself: with TLS Verify, Redis sent AUTH and the password before the certificate was looked at.
    func testVerifySendsNothingToAServerWhoseCertificateIsntTrusted() throws {
        try start()
        let port = port, secret = secret
        let result = within { try RedisDriver(host: "127.0.0.1", port: port, user: "", password: secret, database: "", tls: TLSOptions(.verify)) }
        XCTAssertTrue(message(result).contains("certificate isn't trusted"), message(result))
        XCTAssertFalse(arrives(secret, within: 1), "the password never reached the server")
        XCTAssertFalse(output.text.contains("AUTH"))

        let cassandra = within { try CassandraDriver(host: "127.0.0.1", port: port, user: "u", password: secret, keyspace: "", tls: TLSOptions(.verify)) }
        XCTAssertTrue(message(cassandra).contains("certificate isn't trusted"), message(cassandra))
        XCTAssertFalse(arrives(secret, within: 0.5))
    }

    func testTheHandshakeChecksTheCertificateBeforeTheFirstWrite() throws {
        try start()
        let socket = try Socket(host: "127.0.0.1", port: port)
        defer { socket.close() }
        XCTAssertThrowsError(try socket.startTLS(TLSOptions(.verify))) { XCTAssertTrue(($0 as? DatabaseError)?.message.contains("isn't trusted") == true, "\($0)") }
        XCTAssertFalse(socket.isEncrypted)
        XCTAssertFalse(socket.peerVerified)
        XCTAssertTrue(socket.isClosed, "a refused server gets nothing more")
    }

    func testRequireEncryptsWithoutChecking() throws {
        try start()
        let socket = try Socket(host: "127.0.0.1", port: port)
        defer { socket.close() }
        try socket.startTLS(TLSOptions(.require))
        XCTAssertTrue(socket.isEncrypted)
        XCTAssertFalse(socket.peerVerified, "encrypted, but nothing says who the server is")
        try socket.write(Array("hello through tls\n".utf8))
        XCTAssertTrue(arrives("hello through tls"))
    }

    func testVerifyWithYourOwnCAChecksTheNameToo() throws {
        try start()
        var options = TLSOptions(.verify, anchors: try ownCA())
        // The certificate is for "localhost"; the connection goes to 127.0.0.1, as it does through a tunnel.
        options.peerName = "localhost"
        let good = try Socket(host: "127.0.0.1", port: port)
        defer { good.close() }
        try good.startTLS(options)
        XCTAssertTrue(good.isEncrypted && good.peerVerified)
        try good.write(Array("checked and sent\n".utf8))
        XCTAssertTrue(arrives("checked and sent"))
        good.close()

        options.peerName = "db.example.com"
        let wrongName = try Socket(host: "127.0.0.1", port: port)
        defer { wrongName.close() }
        XCTAssertThrowsError(try wrongName.startTLS(options), "the right CA, but a certificate for another name")

        options.peerName = nil
        let byAddress = try Socket(host: "127.0.0.1", port: port)
        defer { byAddress.close() }
        XCTAssertThrowsError(try byAddress.startTLS(options), "the certificate doesn't name 127.0.0.1")
    }

    func testHTTPSChecksTheCertificateUnlessRequireWasChosen() throws {
        try start(www: true)
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/"))
        let secret = secret
        func get(_ options: TLSOptions) -> Result<HTTPClient.Response, Error>? {
            let client = HTTPClient(tls: options, host: "127.0.0.1")
            client.timeout = 10
            defer { client.close() }
            return within { try client.send(url, method: "GET", headers: ["Authorization": "Bearer \(secret)"]) }
        }
        // Prefer used to accept any certificate here; a token went to whoever answered.
        for mode in [ConnectionConfig.TLS.prefer, .verify, .off] {
            let result = get(TLSOptions(mode))
            XCTAssertTrue(message(result).contains("certificate isn't trusted"), "\(mode): \(message(result))")
        }
        guard case .success(let response)? = get(TLSOptions(.require)) else { return XCTFail("Require accepts the certificate") }
        XCTAssertEqual(response.status, 200)
        // Your own CA and the name the certificate is for.
        var options = TLSOptions(.verify, anchors: try ownCA())
        options.peerName = "localhost"
        guard case .success? = get(options) else { return XCTFail("your own CA is trusted for its name") }
        options.peerName = "db.example.com"
        XCTAssertTrue(message(get(options)).contains("certificate isn't trusted"))
    }
}
