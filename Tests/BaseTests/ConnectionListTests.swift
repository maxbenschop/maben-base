@testable import Base
@testable import BaseCore
import XCTest

/// The connection editor's model: the TLS mode a new connection starts with, and which saved passwords it
/// hands to a connection. The Keychain is a dictionary here.
@MainActor
final class ConnectionListTests: XCTestCase {
    private final class MemoryVault: SecretVault {
        var items: [String: (password: String, binding: String?)] = [:]
        func read(_ account: String) -> (password: String, binding: String?)? { items[account] }
        func write(_ account: String, password: String, binding: String) { items[account] = (password, binding) }
        func bind(_ account: String, to binding: String) -> Bool {
            guard let item = items[account] else { return false }
            items[account] = (item.password, binding)
            return true
        }
        func delete(_ account: String) { items[account] = nil }
    }

    private var vault: MemoryVault!
    private var real: SecretVault!
    private var folder: URL!

    override func setUp() async throws {
        real = Keychain.vault
        vault = MemoryVault()
        Keychain.vault = vault
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-list-\(UUID())")
    }

    override func tearDown() async throws {
        Keychain.vault = real
        try? FileManager.default.removeItem(at: folder)
    }

    func testANewConnectionsTLSFollowsItsHostUntilYouChoose() {
        let list = ConnectionList(store: Store(folder: folder), persist: false, initial: [])
        list.newConnection(kind: .postgres)
        XCTAssertEqual(list.draft.tls, .prefer, "127.0.0.1")
        list.draft.host = "db.example.com"
        list.followHostWithTLS()
        XCTAssertEqual(list.draft.tls, .verify)
        list.draft.host = "192.168.1.9"
        list.followHostWithTLS()
        XCTAssertEqual(list.draft.tls, .prefer)
        // Once chosen by hand, the host doesn't change it any more.
        list.draft.tls = .off
        list.tlsChosen = true
        list.draft.host = "db.example.com"
        list.followHostWithTLS()
        XCTAssertEqual(list.draft.tls, .off)
        list.newConnection(kind: .redis)
        XCTAssertEqual(list.draft.tls, .off, "a local Redis is plain")
        list.newConnection(kind: .sqlite)
        XCTAssertEqual(list.draft.tls, .off)
    }

    func testASavedConnectionKeepsItsTLSModeWhenItsHostIsEdited() {
        var saved = ConnectionConfig()
        saved.host = "db.example.com"
        saved.tls = .prefer
        let list = ConnectionList(store: Store(folder: folder), persist: false, initial: [saved])
        list.select(saved.id)
        list.draft.host = "other.example.com"
        list.followHostWithTLS()
        XCTAssertEqual(list.draft.tls, .prefer)
    }

    func testSecretsAreOnlyLoadedForTheServerTheyWereSavedFor() {
        var c = ConnectionConfig()
        c.host = "db.example.com"
        c.user = "app"
        c.sshEnabled = true
        c.sshHost = "bastion.example.com"
        Secrets(password: "db-pw", ssh: "ssh-pw").save(c)
        var loaded = Secrets.load(c)
        XCTAssertEqual(loaded.password, "db-pw")
        XCTAssertEqual(loaded.ssh, "ssh-pw")
        XCTAssertTrue(loaded.withheld.isEmpty)

        // The same connection as it would arrive from a file or from sync, pointing at another server.
        var moved = c
        moved.host = "evil.example.net"
        loaded = Secrets.load(moved)
        XCTAssertNil(loaded.password)
        XCTAssertEqual(loaded.ssh, "ssh-pw", "the SSH server is the same one")
        XCTAssertEqual(loaded.withheld, [.password])
    }

    func testTheEditorShowsAWithheldPasswordAndSavingMovesIt() {
        var c = ConnectionConfig()
        c.name = "Shop"
        c.host = "db.example.com"
        c.user = "app"
        let store = Store(folder: folder)
        store.save(connections: [c])
        Secrets(password: "db-pw").save(c)

        // Another Mac changed the host and it came in through sync.
        var synced = c
        synced.host = "moved.example.com"
        store.save(connections: [synced])
        let list = ConnectionList(store: store)
        list.select(c.id)
        XCTAssertEqual(list.password, "", "not handed to the new host")
        XCTAssertEqual(list.withheld, [.password])
        XCTAssertEqual(vault.items[c.secretAccount(.password)]?.password, "db-pw", "still there for the host it was saved for")

        // Typed again and saved: now it belongs to the new host.
        list.password = "new-pw"
        list.save()
        XCTAssertTrue(list.withheld.isEmpty)
        XCTAssertEqual(Secrets.load(synced).password, "new-pw")
        XCTAssertNil(Secrets.load(c).password)
    }

    func testEditingTheHostByHandKeepsThePassword() {
        var c = ConnectionConfig()
        c.host = "db.example.com"
        let store = Store(folder: folder)
        store.save(connections: [c])
        Secrets(password: "db-pw").save(c)
        let list = ConnectionList(store: store)
        list.select(c.id)
        XCTAssertEqual(list.password, "db-pw")
        list.draft.host = "db2.example.com\n"   // pasted with its line break
        list.save()
        XCTAssertEqual(list.connections.first?.host, "db2.example.com", "control characters are taken out on saving")
        XCTAssertEqual(Secrets.load(list.connections[0]).password, "db-pw")
    }

    func testOpeningTheListTiesOlderPasswordsToTheirServersOnce() {
        var c = ConnectionConfig()
        c.host = "db.example.com"
        let store = Store(folder: folder)
        store.save(connections: [c])
        vault.items[c.secretAccount(.password)] = ("from-0.2", nil)   // as version 0.2 saved it
        let list = ConnectionList(store: store)
        list.select(c.id)
        XCTAssertEqual(list.password, "from-0.2")
        XCTAssertTrue(list.withheld.isEmpty)
    }

    func testCSVFilesProtectAgainstFormulasWhenAsked() {
        let columns = [ResultColumn(name: "a", typeName: "")]
        let rows: [[String?]] = [["=1+1"], ["-5"]]
        let d = Dialect(kind: .sqlite)
        XCTAssertEqual(String(decoding: ExportFormat.csv.data(columns: columns, rows: rows, name: "t", table: nil, dialect: d, protectFormulas: true), as: UTF8.self), "a\n'=1+1\n-5\n")
        XCTAssertEqual(String(decoding: ExportFormat.csv.data(columns: columns, rows: rows, name: "t", table: nil, dialect: d, protectFormulas: false), as: UTF8.self), "a\n=1+1\n-5\n")
        XCTAssertEqual(CSVOptions.checkbox().title, "Protect against spreadsheet formulas")
    }
}
