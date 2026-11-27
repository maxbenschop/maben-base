@testable import BaseCore
import XCTest

/// What a hostile server, a hostile row or a connection from someone else must not be able to do.
/// Everything here runs without a server; `WireTests` has the cases that need something on the other end.
final class TLSPolicyTests: XCTestCase {
    private func parsed(_ url: String) -> ConnectionConfig {
        var c = ConnectionConfig()
        XCTAssertTrue(c.apply(url: url).ok, url)
        return c
    }

    func testNearAndFarHosts() {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "127.9.9.9", "::1", "[::1]", "mac.local", "10.1.2.3", "172.16.0.1", "172.31.255.255",
                     "192.168.1.5", "169.254.10.10", "fe80::1%en0", "fd12:3456::1", "::ffff:192.168.1.1", "/tmp/.s.PGSQL.5432", "",
                     "http://127.0.0.1:8080", "127.0.0.1:27017,localhost:27018"] {
            XCTAssertTrue(HostScope.isLocal(host), host)
        }
        for host in ["db.example.com", "8.8.8.8", "172.32.0.1", "192.169.1.1", "2001:db8::1", "localhost.example.com", "example.local.com",
                     "https://db.turso.io", "127.0.0.1:27017,db.example.com:27017", "::ffff:8.8.8.8"] {
            XCTAssertFalse(HostScope.isLocal(host), host)
        }
    }

    func testNewConnectionsVerifyServersOutOnTheInternet() {
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .postgres, host: "db.example.com"), .verify)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .redis, host: "cache.example.com"), .verify)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .clickhouse, host: "ch.example.com"), .verify)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .postgres, host: "127.0.0.1"), .prefer)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .mysql, host: "192.168.1.20"), .prefer)
        // No asking the server first: nearby these are plain.
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .redis, host: "localhost"), .off)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .libsql, host: "127.0.0.1"), .off)
        XCTAssertEqual(ConnectionConfig.defaultTLS(kind: .sqlite, host: "db.example.com"), .off)
    }

    func testASavedConnectionKeepsItsMode() throws {
        let json = #"[{"name":"Old","kind":"postgres","host":"db.example.com","tls":"prefer"},{"name":"Older","kind":"mysql","host":"db.example.com"}]"#
        let list = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.tls), [.prefer, .prefer])
    }

    func testURLsThatMeanTLSMeanACheckedCertificate() {
        XCTAssertEqual(parsed("rediss://:pw@cache.example.com:6380/0").tls, .verify)
        XCTAssertEqual(parsed("mongodb+srv://u:p@cluster0.example.mongodb.net/shop").tls, .verify)
        XCTAssertEqual(parsed("turso://db-org.turso.io").tls, .verify)
        XCTAssertEqual(parsed("libsql://db-org.turso.io").tls, .verify)
        XCTAssertEqual(parsed("libsql://db-org.turso.io").port, 443)
        XCTAssertEqual(parsed("clickhouses://u:p@ch.example.com/default").tls, .verify)
        XCTAssertEqual(parsed("postgres://u:p@db.example.com/x?sslmode=verify-full").tls, .verify)
        XCTAssertEqual(parsed("postgres://u:p@db.example.com/x?sslmode=verify-ca").tls, .verify)
        XCTAssertEqual(parsed("mongodb://u:p@db.example.com/x?tls=true").tls, .verify)
        XCTAssertEqual(parsed("sqlserver://sa:p@db.example.com/master?encrypt=true").tls, .verify)
        // Said in so many words: encrypted, certificate not checked.
        XCTAssertEqual(parsed("postgres://u:p@db.example.com/x?sslmode=require").tls, .require)
        XCTAssertEqual(parsed("mysql://u:p@db.example.com/x?ssl-mode=REQUIRED").tls, .require)
        XCTAssertEqual(parsed("mongodb://u:p@db.example.com/x?tls=true&tlsInsecure=true").tls, .require)
        XCTAssertEqual(parsed("sqlserver://sa:p@db.example.com/master?encrypt=true&trustServerCertificate=true").tls, .require)
        XCTAssertEqual(parsed("postgres://u:p@db.example.com/x?sslmode=disable").tls, .off)
        XCTAssertEqual(parsed("sqlserver://sa:p@db.example.com/master?encrypt=false").tls, .off)
    }

    func testAURLThatSaysNothingAboutTLSFollowsTheHost() {
        XCTAssertEqual(parsed("postgres://u:p@db.example.com/x").tls, .verify)
        XCTAssertEqual(parsed("mysql://root@localhost/app").tls, .prefer)
        XCTAssertEqual(parsed("sqlserver://sa:p@db.example.com/master").tls, .verify)
        XCTAssertEqual(parsed("sqlserver://sa:p@127.0.0.1:51433/master").tls, .prefer)
        XCTAssertEqual(parsed("cassandra://db.example.com/ks").tls, .verify)
        XCTAssertEqual(parsed("cassandra://127.0.0.1:59042/mb").tls, .off)
        // A sqld on this Mac is plain HTTP on its own port.
        XCTAssertEqual(parsed("libsql://127.0.0.1:58080").tls, .off)
        XCTAssertEqual(parsed("libsql://127.0.0.1:58080").port, 58080)
        // These schemes are the plain ones of a pair.
        XCTAssertEqual(parsed("redis://:pw@127.0.0.1:6379/1").tls, .off)
        XCTAssertEqual(parsed("clickhouse://u:p@127.0.0.1:8123/default").tls, .off)
    }

    func testPreferOnlyGoesOnPlainNearby() {
        XCTAssertTrue(PlainText.mayFallBack(host: "127.0.0.1", mode: .prefer))
        XCTAssertTrue(PlainText.mayFallBack(host: "db.local", mode: .prefer))
        XCTAssertFalse(PlainText.mayFallBack(host: "db.example.com", mode: .prefer))
        XCTAssertFalse(PlainText.mayFallBack(host: "127.0.0.1", mode: .require))
        XCTAssertFalse(PlainText.mayFallBack(host: "127.0.0.1", mode: .verify))
        let error = PlainText.noTLS(host: "db.example.com", mode: .prefer)
        XCTAssertTrue(error.message.contains("nothing was sent"))
        XCTAssertTrue(error.detail?.contains("set TLS to Off") == true, "says how to get a plain connection on purpose")
    }

    func testAReadablePasswordOnlyGoesOutEncryptedNearbyOrWithTLSOff() {
        XCTAssertTrue(PlainText.maySendPassword(encrypted: true, host: "db.example.com", mode: .require))
        XCTAssertTrue(PlainText.maySendPassword(encrypted: false, host: "localhost", mode: .prefer))
        XCTAssertTrue(PlainText.maySendPassword(encrypted: false, host: "db.example.com", mode: .off))
        XCTAssertFalse(PlainText.maySendPassword(encrypted: false, host: "db.example.com", mode: .prefer))
        XCTAssertFalse(PlainText.maySendPassword(encrypted: false, host: "db.example.com", mode: .verify))
    }

    func testMySQLClearPasswordNeedsACheckedServer() {
        XCTAssertTrue(MySQLDriver.mayUseClearPassword(host: "db.example.com", verified: true))
        XCTAssertFalse(MySQLDriver.mayUseClearPassword(host: "db.example.com", verified: false), "encrypted but unchecked isn't enough")
        XCTAssertTrue(MySQLDriver.mayUseClearPassword(host: "127.0.0.1", verified: false))
        XCTAssertTrue(MySQLDriver.mayUseClearPassword(host: "/tmp/mysql.sock", verified: false))
    }

    func testSQLServerRequireAndVerifyInsistOnTheWholeSession() throws {
        for mode in [ConnectionConfig.TLS.require, .verify] {
            XCTAssertEqual(try SQLServerDriver.plan(mode: mode, answer: 0x01, host: "db.example.com"), .session)
            XCTAssertEqual(try SQLServerDriver.plan(mode: mode, answer: 0x03, host: "db.example.com"), .session)
            XCTAssertThrowsError(try SQLServerDriver.plan(mode: mode, answer: 0x00, host: "db.example.com"), "login-only")
            XCTAssertThrowsError(try SQLServerDriver.plan(mode: mode, answer: 0x02, host: "db.example.com"), "not supported")
            XCTAssertThrowsError(try SQLServerDriver.plan(mode: mode, answer: 0x00, host: "127.0.0.1"), "nearby too")
            XCTAssertThrowsError(try SQLServerDriver.plan(mode: mode, answer: 0x7F, host: "db.example.com"), "an answer that isn't one")
        }
        XCTAssertEqual(try SQLServerDriver.plan(mode: .prefer, answer: 0x01, host: "db.example.com"), .session)
        XCTAssertThrowsError(try SQLServerDriver.plan(mode: .prefer, answer: 0x02, host: "db.example.com"), "the login would go out plain")
        XCTAssertThrowsError(try SQLServerDriver.plan(mode: .prefer, answer: 0x00, host: "db.example.com"))
        XCTAssertEqual(try SQLServerDriver.plan(mode: .prefer, answer: 0x02, host: "127.0.0.1"), SQLServerDriver.Encryption.none)
        XCTAssertEqual(try SQLServerDriver.plan(mode: .prefer, answer: 0x00, host: "127.0.0.1"), .loginOnly)
        XCTAssertEqual(try SQLServerDriver.plan(mode: .off, answer: 0x02, host: "db.example.com"), SQLServerDriver.Encryption.none)
        XCTAssertThrowsError(try SQLServerDriver.plan(mode: .off, answer: 0x03, host: "db.example.com"))
    }

    func testHTTPEnginesDontSendTheSignInPlainToTheInternet() throws {
        XCTAssertEqual(try HTTPClient.endpoint(host: "ch.example.com", port: 8443, tls: .verify).absoluteString, "https://ch.example.com:8443")
        XCTAssertEqual(try HTTPClient.endpoint(host: "ch.example.com", port: 8443, tls: .prefer).scheme, "https")
        XCTAssertEqual(try HTTPClient.endpoint(host: "libsql://db-org.turso.io", port: 443, tls: .verify).absoluteString, "https://db-org.turso.io")
        XCTAssertEqual(try HTTPClient.endpoint(host: "https://db-org.turso.io", port: 8080, tls: .off).scheme, "https", "an https address stays HTTPS")
        for mode in [ConnectionConfig.TLS.prefer, .require, .verify] {
            XCTAssertThrowsError(try HTTPClient.endpoint(host: "http://db.example.com", port: 8080, tls: mode), "\(mode)")
            XCTAssertThrowsError(try HTTPClient.endpoint(host: "HTTP://db.example.com", port: 8080, tls: mode), "\(mode)")
        }
        // Plain HTTP is for this Mac and private networks, or for when you chose TLS Off.
        XCTAssertEqual(try HTTPClient.endpoint(host: "http://127.0.0.1:8080", port: 8080, tls: .prefer).absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(try HTTPClient.endpoint(host: "127.0.0.1", port: 8123, tls: .off).absoluteString, "http://127.0.0.1:8123")
        XCTAssertEqual(try HTTPClient.endpoint(host: "ch.example.com", port: 8123, tls: .off).scheme, "http")
        XCTAssertThrowsError(try HTTPClient.endpoint(host: "ftp://db.example.com", port: 21, tls: .off))
    }

    func testATokenOnlyGoesToHTTPSOrNearby() throws {
        XCTAssertNoThrow(try HTTPClient.tokenEndpoint("https://oauth2.googleapis.com/token"))
        XCTAssertNoThrow(try HTTPClient.tokenEndpoint("http://127.0.0.1:9050"))
        XCTAssertThrowsError(try HTTPClient.tokenEndpoint("http://oauth2.example.com/token"))
        XCTAssertThrowsError(try HTTPClient.tokenEndpoint("file:///etc/passwd"))
        XCTAssertThrowsError(try HTTPClient.tokenEndpoint("not a url"))
    }

    func testAServerCanOnlyMoveASessionWithinItsOwnDomain() throws {
        let base = try XCTUnwrap(URL(string: "https://db-org.aws-eu-west-1.turso.io"))
        func may(_ next: String) -> Bool { URL(string: next).map { HTTPClient.mayMove(from: base, to: $0) } ?? false }
        XCTAssertTrue(may("https://db-org.aws-eu-west-1.turso.io/v2"))
        XCTAssertTrue(may("https://node7.aws-eu-west-1.turso.io"))
        XCTAssertFalse(may("https://collector.example.com"))
        XCTAssertFalse(may("http://db-org.aws-eu-west-1.turso.io"), "not down to plain HTTP")
        XCTAssertFalse(may("https://db-org.aws-eu-west-1.turso.io:8443"))
        XCTAssertFalse(may("https://turso.io.example.com"))
        XCTAssertFalse(may("https://user@node7.aws-eu-west-1.turso.io"))
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        XCTAssertTrue(HTTPClient.mayMove(from: local, to: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/x"))))
        XCTAssertFalse(HTTPClient.mayMove(from: local, to: try XCTUnwrap(URL(string: "https://127.0.0.2"))))
    }

    func testEveryModeSaysWhatItDoes() {
        for kind in DatabaseKind.allCases {
            for mode in ConnectionConfig.TLS.allCases {
                let help = mode.help(for: kind)
                XCTAssertTrue(help.hasSuffix(".") && help.count > 20, "\(kind) \(mode)")
            }
        }
        XCTAssertTrue(ConnectionConfig.TLS.prefer.help(for: .clickhouse).contains("checks the server's certificate"))
        XCTAssertTrue(ConnectionConfig.TLS.prefer.help(for: .postgres).contains("only on this Mac or a private network"))
        XCTAssertTrue(ConnectionConfig.TLS.require.help(for: .postgres).contains("accepts any certificate"))
    }
}

final class ConnectionSafetyTests: XCTestCase {
    func testAURLNeverChoosesAProgramToRun() {
        var c = ConnectionConfig()
        XCTAssertTrue(c.apply(url: "oracle://u:p@db.example.com:1521/FREEPDB1?tool=/tmp/evil").ok)
        XCTAssertEqual(c.localToolPath, "")
        XCTAssertNil(c.options["tool"])
        var d = ConnectionConfig()
        XCTAssertTrue(d.apply(url: "duckdb:///tmp/x.duckdb?tool=/tmp/evil").ok)
        XCTAssertEqual(d.localToolPath, "")
        XCTAssertNil(d.options["tool"])
    }

    func testAFileOrTheSyncedListNeverChoosesAProgramToRun() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"oracle","host":"db","options":{"tool":"/tmp/evil","schema":"S"},"localToolPath":"/tmp/evil"}]"#
        let c = try XCTUnwrap(try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8)).first)
        XCTAssertEqual(c.localToolPath, "")
        XCTAssertEqual(c.options, ["schema": "S"])

        var mine = ConnectionConfig()
        mine.kind = .oracle
        mine.localToolPath = "/opt/oracle/sqlplus"
        let written = String(decoding: try JSONEncoder().encode(mine), as: UTF8.self)
        XCTAssertFalse(written.contains("sqlplus"), "the path isn't in what is exported or synced")
    }

    func testTheToolPathStaysInThisMacsOwnFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        var c = ConnectionConfig()
        c.kind = .duckdb
        c.localToolPath = "/opt/homebrew/bin/duckdb"
        store.save(connections: [c])
        XCTAssertEqual(store.connections().first?.localToolPath, "/opt/homebrew/bin/duckdb")
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("connections.json"), encoding: .utf8).contains("homebrew"))
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("tools.json"), encoding: .utf8).contains("homebrew"))
        store.forget(connection: c.id)
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("tools.json"), encoding: .utf8).contains("homebrew"))
    }

    func testSyncKeepsThisMacsToolPath() {
        var mine = ConnectionConfig()
        mine.localToolPath = "/opt/oracle/sqlplus"
        mine.modified = Date(timeIntervalSince1970: 10)
        var theirs = mine
        theirs.localToolPath = ""
        theirs.host = "other.example.com"
        theirs.modified = Date(timeIntervalSince1970: 20)
        let merged = ConnectionMerge.merge(local: [mine], remote: [theirs], deleted: [:])
        XCTAssertEqual(merged.first?.host, "other.example.com")
        XCTAssertEqual(merged.first?.localToolPath, "/opt/oracle/sqlplus")
    }

    func testControlCharactersAreRefusedInEveryField() {
        for url in ["postgres://u:p@db.example.com/x%0Ay", "postgres://u%0D:p@db.example.com/x", "oracle://u:p@db.example.com/svc%0AHOST%20id",
                    "postgres://u:p@db.example.com/x?sslrootcert=a%0Ab", "sqlite:///tmp/a%00b.sqlite", "mongodb://u:p@db.example.com/x?authSource=a%E2%80%A8b"] {
            var c = ConnectionConfig()
            c.name = "before"
            XCTAssertFalse(c.apply(url: url).ok, url)
            XCTAssertEqual(c.name, "before", "a refused URL changes nothing")
            XCTAssertEqual(c.host, "127.0.0.1")
        }
        var c = ConnectionConfig()
        XCTAssertTrue(c.isWellFormed)
        c.sshHost = "bastion\n-oProxyCommand=id"
        XCTAssertFalse(c.isWellFormed)
        XCTAssertThrowsError(try Connector.open(c, password: nil)) { XCTAssertTrue(($0 as? DatabaseError)?.message.contains("characters that can't be used") == true) }
        c.stripControlCharacters()
        XCTAssertEqual(c.sshHost, "bastion-oProxyCommand=id")
        XCTAssertTrue(c.isWellFormed)
        c.options["role"] = "a\u{2028}b"
        XCTAssertFalse(c.isWellFormed)
    }

    func testSyncLeavesOutAConnectionWithControlCharacters() {
        var bad = ConnectionConfig()
        bad.host = "db.example.com\r\nx"
        bad.modified = Date(timeIntervalSince1970: 20)
        var good = ConnectionConfig()
        good.name = "good"
        XCTAssertEqual(ConnectionMerge.merge(local: [], remote: [bad, good], deleted: [:]).map(\.name), ["good"])
    }

    func testSavedConnectionsLoseControlCharactersOnTheWayIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"[{"name":"Old","kind":"oracle","host":"db\nHOST id","user":"u"}]"#.utf8).write(to: folder.appendingPathComponent("connections.json"))
        XCTAssertEqual(Store(folder: folder).connections().first?.host, "dbHOST id")
    }

    // MARK: SSH

    private func tunnel(_ change: (inout ConnectionConfig) -> Void) -> ConnectionConfig {
        var c = ConnectionConfig()
        c.host = "10.0.0.5"
        c.port = 5432
        c.sshEnabled = true
        c.sshHost = "bastion.example.com"
        c.sshUser = "deploy"
        change(&c)
        return c
    }

    func testSSHArgumentsEndWithTheServerAfterTwoHyphens() throws {
        let args = try SSHTunnel.arguments(config: tunnel { _ in }, localPort: 50123, hasSecret: false)
        XCTAssertEqual(Array(args.suffix(2)), ["--", "deploy@bastion.example.com"])
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(args.contains("ControlPath=none"), "this ssh listens itself, so the port is known to be its own")
        XCTAssertTrue(args.contains("127.0.0.1:50123:10.0.0.5:5432"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        let v6 = try SSHTunnel.arguments(config: tunnel { $0.host = "fd00::5"; $0.sshUser = ""; $0.sshPort = 2222 }, localPort: 50123, hasSecret: true)
        XCTAssertTrue(v6.contains("127.0.0.1:50123:[fd00::5]:5432"))
        XCTAssertEqual(Array(v6.suffix(2)), ["--", "bastion.example.com"])
        XCTAssertTrue(v6.contains("2222") && v6.contains("NumberOfPasswordPrompts=1"))
    }

    func testSSHRefusesNamesItWouldMisread() {
        let bad: [(inout ConnectionConfig) -> Void] = [
            { $0.sshHost = "-oProxyCommand=touch /tmp/x" }, { $0.sshHost = "" }, { $0.sshHost = "bastion\n-v" }, { $0.sshHost = "bastion x" },
            { $0.sshUser = "-l root" }, { $0.sshUser = "a\rb" }, { $0.sshUser = "a@b" },
            { $0.host = "-x" }, { $0.host = "db\n" }, { $0.host = "a,b" }, { $0.host = "" }, { $0.port = 0 }, { $0.port = 70000 }, { $0.sshPort = -1 },
        ]
        for (i, change) in bad.enumerated() {
            XCTAssertThrowsError(try SSHTunnel.arguments(config: tunnel(change), localPort: 50123, hasSecret: false), "case \(i)")
        }
        XCTAssertThrowsError(try SSHTunnel(config: tunnel { $0.sshHost = "-oProxyCommand=id" }), "nothing is started for a host like that")
    }

    func testTheTunnelsPortMustBeThisProcessesOwn() throws {
        // A socket of this test listening on a port: the check finds it for this process, and for no other port or process.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertFalse(SSHTunnel.isListening(pid: getpid(), port: port), "bound but not listening yet")
        XCTAssertEqual(listen(fd, 1), 0)
        XCTAssertTrue(SSHTunnel.isListening(pid: getpid(), port: port))
        XCTAssertFalse(SSHTunnel.isListening(pid: getpid(), port: port == 65535 ? 1 : port + 1))
        XCTAssertFalse(SSHTunnel.isListening(pid: 1, port: port), "another process listening wouldn't count")
        XCTAssertTrue(SSHTunnel.canConnect(port: port), "being able to connect is what the old check went by")
    }
}

/// Passwords in the Keychain, with a dictionary standing in for it.
final class SecretBindingTests: XCTestCase {
    private final class MemoryVault: SecretVault {
        var items: [String: (password: String, binding: String?)] = [:]
        var canBind = true
        func read(_ account: String) -> (password: String, binding: String?)? { items[account] }
        func write(_ account: String, password: String, binding: String) { items[account] = (password, binding) }
        func bind(_ account: String, to binding: String) -> Bool {
            guard canBind, let item = items[account] else { return false }
            items[account] = (item.password, binding)
            return true
        }
        func delete(_ account: String) { items[account] = nil }
    }

    private var vault: MemoryVault!
    private var real: SecretVault!

    override func setUp() {
        real = Keychain.vault
        vault = MemoryVault()
        Keychain.vault = vault
    }

    override func tearDown() { Keychain.vault = real }

    private func connection() -> ConnectionConfig {
        var c = ConnectionConfig()
        c.host = "db.example.com"
        c.user = "app"
        c.sshHost = "bastion.example.com"
        return c
    }

    func testAPasswordIsOnlyHandedBackForTheServerItWasSavedFor() {
        let c = connection()
        Keychain.set("s3cret", account: c.secretAccount(.password), binding: c.secretBinding(.password))
        XCTAssertEqual(Keychain.lookup(account: c.secretAccount(.password), binding: c.secretBinding(.password)), .found("s3cret"))

        // The same ID arrives from a file or from sync, pointing somewhere else.
        for change: (inout ConnectionConfig) -> Void in [{ $0.host = "evil.example.net" }, { $0.port = 6543 }, { $0.user = "postgres" }, { $0.kind = .mysql },
                                                        { $0.sshEnabled = true }, { $0.options["endpoint"] = "https://evil.example.net" }] {
            var other = c
            change(&other)
            XCTAssertEqual(other.secretAccount(.password), c.secretAccount(.password))
            XCTAssertEqual(Keychain.lookup(account: other.secretAccount(.password), binding: other.secretBinding(.password)), .elsewhere)
            XCTAssertNil(Keychain.password(account: other.secretAccount(.password), binding: other.secretBinding(.password)))
        }
        // What doesn't say where the password goes may change freely.
        var renamed = c
        renamed.name = "Renamed"
        renamed.database = "other"
        renamed.host = "DB.Example.com"
        renamed.safeMode = .readOnly
        XCTAssertEqual(Keychain.lookup(account: renamed.secretAccount(.password), binding: renamed.secretBinding(.password)), .found("s3cret"))
        XCTAssertEqual(Keychain.lookup(account: UUID().uuidString, binding: c.secretBinding(.password)), Keychain.Lookup.none)
    }

    func testEachSecretIsTiedToItsOwnDestination() {
        var c = connection()
        c.sshEnabled = true
        c.clientCertFile = "~/client.p12"
        let ssh = c.secretBinding(.ssh), cert = c.secretBinding(.certificate), password = c.secretBinding(.password)
        XCTAssertEqual(Set([ssh, cert, password]).count, 3)
        var moved = c
        moved.host = "db2.example.com"
        XCTAssertEqual(moved.secretBinding(.ssh), ssh, "the SSH password goes to the SSH server, which didn't change")
        XCTAssertNotEqual(moved.secretBinding(.password), password)
        moved.sshHost = "other-bastion.example.com"
        XCTAssertNotEqual(moved.secretBinding(.ssh), ssh)
        moved.clientCertFile = "~/other.p12"
        XCTAssertNotEqual(moved.secretBinding(.certificate), cert)
        // No two sets of fields read the same.
        var a = connection(), b = connection()
        a.host = "ab"; a.user = "c"
        b.host = "a"; b.user = "bc"
        XCTAssertNotEqual(a.secretBinding(.password), b.secretBinding(.password))
    }

    func testSavingAgainMovesThePasswordToTheNewServer() {
        var c = connection()
        Keychain.set("s3cret", account: c.secretAccount(.password), binding: c.secretBinding(.password))
        c.host = "new.example.com"   // changed by hand in the editor, then saved
        Keychain.set("s3cret", account: c.secretAccount(.password), binding: c.secretBinding(.password))
        XCTAssertEqual(Keychain.password(account: c.secretAccount(.password), binding: c.secretBinding(.password)), "s3cret")
        Keychain.set("", account: c.secretAccount(.password), binding: c.secretBinding(.password))
        XCTAssertEqual(Keychain.lookup(account: c.secretAccount(.password), binding: c.secretBinding(.password)), Keychain.Lookup.none)
    }

    func testPasswordsFromAnOlderVersionKeepWorkingForUnchangedConnections() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        var c = connection()
        c.sshEnabled = true
        store.save(connections: [c])
        // As older versions saved them: under the ID alone.
        vault.items[c.secretAccount(.password)] = ("old-password", nil)
        vault.items[c.secretAccount(.ssh)] = ("old-ssh", nil)
        let stray = UUID().uuidString
        vault.items[stray] = ("not-a-saved-connection", nil)
        XCTAssertEqual(Keychain.lookup(account: c.secretAccount(.password), binding: c.secretBinding(.password)), .elsewhere, "before the move")

        store.adoptSavedPasswords()
        XCTAssertEqual(Keychain.password(account: c.secretAccount(.password), binding: c.secretBinding(.password)), "old-password")
        XCTAssertEqual(Keychain.password(account: c.secretAccount(.ssh), binding: c.secretBinding(.ssh)), "old-ssh")
        XCTAssertNil(vault.items[stray]?.binding)

        // It happens once. A password that shows up later without a fingerprint is never tied to whatever
        // the connection has become by then.
        var changed = c
        changed.host = "evil.example.net"
        store.save(connections: [changed])
        vault.items[c.secretAccount(.password)] = ("old-password", nil)
        store.adoptSavedPasswords()
        XCTAssertEqual(Keychain.lookup(account: changed.secretAccount(.password), binding: changed.secretBinding(.password)), .elsewhere)
    }

    func testTheMoveNeverRetiesAPasswordThatAlreadyHasAFingerprint() {
        let c = connection()
        Keychain.set("s3cret", account: c.secretAccount(.password), binding: c.secretBinding(.password))
        var other = c
        other.host = "evil.example.net"
        Keychain.adopt(account: other.secretAccount(.password), binding: other.secretBinding(.password))
        XCTAssertEqual(Keychain.lookup(account: other.secretAccount(.password), binding: other.secretBinding(.password)), .elsewhere)
        XCTAssertEqual(Keychain.password(account: c.secretAccount(.password), binding: c.secretBinding(.password)), "s3cret")
        // When the item can't be changed in place it is written again.
        vault.canBind = false
        vault.items["x"] = ("pw", nil)
        Keychain.adopt(account: "x", binding: "v1:abc")
        XCTAssertEqual(Keychain.password(account: "x", binding: "v1:abc"), "pw")
    }

    func testForgettingAConnectionRemovesItsSecrets() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = connection()
        for slot in SecretSlot.allCases { Keychain.set("x", account: c.secretAccount(slot), binding: c.secretBinding(slot)) }
        Store(folder: folder).forget(connection: c.id)
        XCTAssertTrue(vault.items.isEmpty)
    }
}
