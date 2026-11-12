import AppKit
import BaseCore
import SwiftUI

// Maben Base: a free database client for Postgres, MySQL and SQLite.
//
//   --demo   opens a sample SQLite database in a temporary folder; your saved connections aren't read or changed.
//   --demo --open=<table> [--structure] [--edit] [--filter]   opens a table (with staged edits, or the filter bar)
//   --demo --query=<sql>    opens a query tab and runs it
//   --demo --palette        shows the ⌘P palette
//   --demo --connections    shows the connections window instead of connecting
//   --demo --appearance=light|dark   --sheet=newTable|newView|backup|exportDatabase|snippets   --format   --explain   --cells
//   --demo --url=<url>      connects to that database instead (nothing is saved; for testing against a real server)
//   --demo --server=processes|users|metrics   opens the server window (with --url)
//   --demo --also=<url>     opens a second connection too (window tabs)   --split   shows two tabs side by side

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        NSApp.mainMenu = MainMenu.build()
        if let a = Demo.argument("appearance").flatMap(Appearance.init(rawValue:)) { a.apply() }
        if CommandLine.arguments.contains("--demo") {
            Demo.start()
        } else {
            ConnectionsWindowController.shared.list.syncNow()
            if !SessionMemory.reopen() { ConnectionsWindowController.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !CommandLine.arguments.contains("--demo") { SessionMemory.save() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !CommandLine.arguments.contains("--demo") { ConnectionsWindowController.shared.list.syncNow() }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ConnectionsWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = WorkspaceWindowController.open.filter { $0.workspace.hasUnsavedChanges }
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with unsaved changes?"
        alert.informativeText = "Edited rows in \(dirty.map { $0.workspace.config.displayName }.joined(separator: ", ")) haven't been written to the database."
        alert.addButton(withTitle: "Quit without saving").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc func showConnections(_ sender: Any?) { ConnectionsWindowController.shared.show() }
    @objc func newConnection(_ sender: Any?) {
        ConnectionsWindowController.shared.show()
        ConnectionsWindowController.shared.list.newConnection()
    }
    @objc func openSQLiteFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Open a SQLite database"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var c = ConnectionConfig()
        c.kind = .sqlite
        c.filePath = (url.path as NSString).abbreviatingWithTildeInPath
        c.name = url.deletingPathExtension().lastPathComponent
        c.tls = .off
        let list = ConnectionsWindowController.shared.list
        if let existing = list.connections.first(where: { $0.kind == .sqlite && ($0.filePath as NSString).expandingTildeInPath == url.path }) {
            list.select(existing.id)
        } else {
            list.draft = c
            list.password = ""
        }
        list.connect(window: nil)
    }
    @objc func setAppearance(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let a = Appearance(rawValue: raw) else { return }
        Appearance.current = a
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearance(_:)) {
            item.state = (item.representedObject as? String) == Appearance.current.rawValue ? .on : .off
        }
        return true
    }

    @objc func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/maxbenschop/maben-base")!)
    }
}

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, represented: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.representedObject = represented
            return i
        }
        let W = WorkspaceWindowController.self
        let A = AppDelegate.self

        menu("Maben Base", [
            item("About Maben Base", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(A.showSettings(_:)), ","),
            .separator(),
            item("Hide Maben Base", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Maben Base", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("New Connection…", #selector(A.newConnection(_:)), "n"),
            item("Connections", #selector(A.showConnections(_:)), "o", [.command, .shift]),
            item("Open SQLite File…", #selector(A.openSQLiteFile(_:)), "o"),
            .separator(),
            item("New Query", #selector(W.newQueryTab(_:)), "t"),
            item("New Table…", #selector(W.newTable(_:)), "n", [.command, .option]),
            item("New View…", #selector(W.newView(_:)), ""),
            item("Open Anything…", #selector(W.quickOpen(_:)), "p"),
            item("Switch Database…", #selector(W.switchDatabase(_:)), "k"),
            .separator(),
            item("Save Changes", #selector(W.saveChanges(_:)), "s"),
            item("Discard Changes", #selector(W.discardChanges(_:)), "s", [.command, .option]),
            .separator(),
            {
                let i = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.addItem(item("CSV…", #selector(W.exportCurrent(_:)), "e", [.command, .shift], represented: "csv"))
                sub.addItem(item("JSON…", #selector(W.exportCurrent(_:)), "", represented: "json"))
                sub.addItem(item("Excel…", #selector(W.exportCurrent(_:)), "", represented: "xlsx"))
                sub.addItem(item("Markdown…", #selector(W.exportCurrent(_:)), "", represented: "markdown"))
                sub.addItem(item("SQL Inserts…", #selector(W.exportCurrent(_:)), "", represented: "sql"))
                i.submenu = sub
                return i
            }(),
            item("Export Database…", #selector(W.exportDatabase(_:)), "e", [.command, .shift, .option]),
            item("Import CSV…", #selector(W.importCSV(_:)), "i", [.command, .shift]),
            item("Import SQL File…", #selector(W.importSQL(_:)), ""),
            item("Backup and Restore…", #selector(W.backupRestore(_:)), "b", [.command, .shift]),
            item("Server: Processes, Users and Metrics", #selector(W.showServer(_:)), "m", [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(W.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Add Row", #selector(W.addRow(_:)), "i"),
            item("Filter Rows", #selector(W.toggleFilters(_:)), "f"),
            {
                let i = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let f = item("Find in Query…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option])
                f.tag = NSTextFinder.Action.showFindInterface.rawValue
                sub.addItem(f)
                i.submenu = sub
                return i
            }(),
        ])
        menu("Query", [
            item("Run Statement at Cursor", nil, "↩"),
            item("Run All", #selector(W.runAll(_:)), "\r", [.command, .shift]),
            item("Run in New Tab", #selector(W.runInNewTab(_:)), "\r", [.command, .option]),
            item("Stop", #selector(W.cancelQuery(_:)), "."),
            .separator(),
            item("Explain", #selector(W.explainQuery(_:)), "e", [.command, .option]),
            item("Format SQL", #selector(W.formatSQL(_:)), "f", [.option, .shift]),
            item("Open Results in Window", #selector(W.popOutResults(_:)), ""),
            .separator(),
            item("Snippets…", #selector(W.editSnippets(_:)), ""),
        ])
        // ⌘↩ is handled by the editor itself; the menu item only shows the shortcut.
        main.items.last?.submenu?.items.first?.isEnabled = false
        menu("View", [
            item("Refresh", #selector(W.refresh(_:)), "r"),
            item("Data or Structure", #selector(W.showStructure(_:)), "u", [.command, .shift]),
            item("Next Page", #selector(W.nextPage(_:)), "]"),
            item("Previous Page", #selector(W.previousPage(_:)), "["),
            .separator(),
            item("Split View", #selector(W.toggleSplit(_:)), "\\"),
            item("Show or Hide Sidebar", #selector(W.toggleSidebar(_:)), "s", [.command, .control]),
            item("Show or Hide Row Details", #selector(W.toggleInspector(_:)), "i", [.command, .option]),
            {
                let i = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for a in Appearance.allCases {
                    let m = item(a.title, #selector(A.setAppearance(_:)), "", represented: a.rawValue)
                    sub.addItem(m)
                }
                i.submenu = sub
                return i
            }(),
            .separator(),
            item("Next Tab", #selector(W.nextTab(_:)), "}", [.command, .shift]),
            item("Previous Tab", #selector(W.previousTab(_:)), "{", [.command, .shift]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ]
        menu("Window", windowMenu)
        NSApp.windowsMenu = main.items.last?.submenu
        menu("Help", [item("Maben Base on GitHub", #selector(A.openWebsite(_:)), "")])
        return main
    }
}

/// --demo: a sample shop database, so the app can be tried (and screenshotted) without a server.
@MainActor
enum Demo {
    static func start() {
        let folder = NSTemporaryDirectory() + "MabenBaseDemo-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/shop.sqlite"
        do {
            try build(at: path)
        } catch {
            showError(error, in: nil, title: "Couldn't build the demo database")
            return
        }
        if let url = argument("url") {
            var c = ConnectionConfig()
            let parsed = c.apply(url: url)
            c.environment = argument("env").flatMap(ConnectionConfig.Environment.init(rawValue:)) ?? .local
            let list = ConnectionList(store: Store(folder: URL(fileURLWithPath: folder)), persist: false, initial: [c])
            ConnectionsWindowController.shared = ConnectionsWindowController(list: list)
            list.select(c.id)
            list.password = parsed.password ?? ""
            list.connect(window: nil)
            return
        }
        var c = ConnectionConfig()
        c.kind = .sqlite
        c.name = "Demo shop"
        c.filePath = path
        c.environment = .development
        c.tls = .off
        var prod = ConnectionConfig()
        prod.name = "Shop production"
        prod.group = "Clients"
        prod.environment = .production
        prod.host = "db.example.com"
        prod.user = "app"
        prod.database = "shop"
        var staging = prod
        staging.id = UUID()
        staging.name = "Shop staging"
        staging.environment = .staging
        staging.host = "staging.example.com"
        let list = ConnectionList(store: Store(folder: URL(fileURLWithPath: folder)), persist: false, initial: [c, prod, staging])
        ConnectionsWindowController.shared = ConnectionsWindowController(list: list)
        list.select(c.id)
        if CommandLine.arguments.contains("--connections") {
            ConnectionsWindowController.shared.show()
        } else {
            list.connect(window: nil)
        }
        // --also=<url>: a second connection, to see connections as window tabs.
        if let also = argument("also") {
            var c2 = ConnectionConfig()
            let r = c2.apply(url: also)
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let session = try? await Session.open(c2, secrets: Secrets(password: r.password)) {
                    WorkspaceWindowController(session: session, store: Store(folder: URL(fileURLWithPath: folder))).show()
                }
            }
        }
    }

    static func argument(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }

    /// Puts the first workspace in the state the launch flags ask for.
    static func prepare(_ workspace: Workspace) {
        let args = CommandLine.arguments
        Task {
            for _ in 0..<50 where workspace.objects.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let name = argument("open"), let object = workspace.objects.first(where: { $0.name == name }) {
                workspace.open(object, structure: args.contains("--structure"))
                guard let tab = workspace.activeTable else { return }
                for _ in 0..<50 where tab.rows.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
                if args.contains("--filter") {
                    tab.filters = [Filter(column: "city", op: .equals, value: "Utrecht"), Filter(column: "newsletter", op: .equals, value: "1")]
                    tab.showFilters = true
                    tab.applyFilters()
                }
                if args.contains("--edit"), tab.rows.count > 5 {
                    tab.gridEdit(row: 1, column: 3, value: "Leiden")
                    tab.gridEdit(row: 2, column: 1, value: "Bram de Vries")
                    tab.gridDelete(rows: [4])
                    tab.addRow()
                    tab.gridEdit(row: tab.rows.count, column: 1, value: "New customer")
                    tab.gridEdit(row: tab.rows.count, column: 2, value: "new@example.com")
                }
                tab.gridSelectionChanged([1])
            }
            if let sql = argument("query") {
                let q = workspace.newQuery(text: sql)
                if !args.contains("--format") && !args.contains("--explain") { q.run(sql) }
            }
            if args.contains("--palette") { workspace.palette = .open }
            if args.contains("--split"), let other = workspace.objects.first(where: { $0.name == "customers" }) {
                workspace.open(other)
                if let id = workspace.tabs.last?.id { workspace.openOnRight(id) }
            }
            if let page = argument("server").flatMap(AdminModel.Page.init(rawValue:)) ?? argument("server").flatMap({ AdminModel.Page(rawValue: $0.capitalized) }) {
                AdminWindowController.show(for: workspace)
                _ = page
                NotificationCenter.default.post(name: .demoAdminPage, object: page.rawValue)
            }
            if let sheet = argument("sheet").flatMap(Workspace.Sheet.init(rawValue:)) { workspace.sheet = sheet }
            if let q = workspace.activeQuery {
                if args.contains("--format") { try? await Task.sleep(nanoseconds: 300_000_000); q.format() }
                if args.contains("--explain") { try? await Task.sleep(nanoseconds: 300_000_000); q.explain(q.text, analyze: false) }
            }
            if args.contains("--cells"), let tab = workspace.activeTable {
                try? await Task.sleep(nanoseconds: 400_000_000)
                NotificationCenter.default.post(name: .demoSelectCells, object: tab)
            }
        }
    }

    static func build(at path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let db = try SQLiteDriver(path: path, create: true)
        defer { db.close() }
        var rng = SeededRandom(seed: 7)
        let first = ["Anna", "Bram", "Chloé", "Daan", "Emma", "Finn", "Germaine", "Hugo", "Iris", "Jesse", "Kiki", "Lars", "Mila", "Noah", "Olivia", "Pim", "Roos", "Sem", "Tess", "Vince"]
        let last = ["de Vries", "Jansen", "Bakker", "Visser", "Smit", "Meijer", "de Boer", "Mulder", "Bos", "Vos", "Peters", "Hendriks"]
        let cities = ["Amsterdam", "Rotterdam", "Utrecht", "Eindhoven", "Groningen", "Zwolle", "Leiden", "Haarlem", "Nijmegen", "Breda"]
        let products: [(String, String, Double)] = [
            ("Desk lamp", "Lighting", 39.95), ("Floor lamp", "Lighting", 129), ("Oak desk", "Furniture", 449), ("Office chair", "Furniture", 289),
            ("Monitor arm", "Accessories", 79.5), ("Cable tray", "Accessories", 24.99), ("Bookshelf", "Furniture", 199), ("Desk mat", "Accessories", 29),
            ("Pendant light", "Lighting", 159), ("Standing desk", "Furniture", 649), ("Plant pot", "Decor", 19.95), ("Wall clock", "Decor", 45),
            ("Footrest", "Accessories", 49), ("Laptop stand", "Accessories", 59), ("Rug", "Decor", 139), ("Reading light", "Lighting", 69),
        ]
        var sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE customers (
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              email TEXT NOT NULL UNIQUE,
              city TEXT,
              newsletter INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              notes TEXT
            );
            CREATE TABLE products (
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              category TEXT NOT NULL,
              price NUMERIC NOT NULL,
              stock INTEGER NOT NULL DEFAULT 0,
              sku TEXT UNIQUE
            );
            CREATE TABLE orders (
              id INTEGER PRIMARY KEY,
              customer_id INTEGER NOT NULL REFERENCES customers(id),
              status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled')),
              total NUMERIC NOT NULL,
              ordered_at TEXT NOT NULL
            );
            CREATE TABLE order_items (
              order_id INTEGER NOT NULL REFERENCES orders(id),
              product_id INTEGER NOT NULL REFERENCES products(id),
              quantity INTEGER NOT NULL,
              price NUMERIC NOT NULL,
              PRIMARY KEY (order_id, product_id)
            );
            CREATE TABLE audit_log (at TEXT, message TEXT);
            CREATE INDEX orders_customer ON orders(customer_id);
            CREATE INDEX orders_status ON orders(status, ordered_at);
            CREATE VIEW revenue_by_month AS
              SELECT substr(ordered_at, 1, 7) AS month, COUNT(*) AS orders, ROUND(SUM(total), 2) AS revenue
              FROM orders WHERE status <> 'cancelled' GROUP BY 1 ORDER BY 1 DESC;
            BEGIN;

            """
        for (i, p) in products.enumerated() {
            sql += "INSERT INTO products VALUES (\(i + 1), '\(p.0)', '\(p.1)', \(p.2), \(rng.next(200)), 'MB-\(String(format: "%04d", 1000 + i * 7))');\n"
        }
        for i in 1...480 {
            let f = first[rng.next(first.count)], l = last[rng.next(last.count)]
            let email = "\(f.lowercased().folding(options: .diacriticInsensitive, locale: nil)).\(l.lowercased().replacingOccurrences(of: " ", with: ""))\(i)@example.com"
            let city = rng.next(9) == 0 ? "NULL" : "'\(cities[rng.next(cities.count)])'"
            let note = rng.next(7) == 0 ? "'Prefers delivery after 18:00'" : "NULL"
            sql += "INSERT INTO customers VALUES (\(i), '\(f) \(l)', '\(email)', \(city), \(rng.next(2)), datetime('2025-01-01', '+\(rng.next(600)) days', '+\(rng.next(86400)) seconds'), \(note));\n"
        }
        let statuses = ["paid", "paid", "paid", "shipped", "shipped", "pending", "cancelled"]
        for i in 1...2400 {
            var total = 0.0
            var items: [String] = []
            var used = Set<Int>()
            for _ in 0..<(1 + rng.next(3)) {
                let p = rng.next(products.count)
                guard used.insert(p).inserted else { continue }
                let q = 1 + rng.next(3)
                total += Double(q) * products[p].2
                items.append("INSERT INTO order_items VALUES (\(i), \(p + 1), \(q), \(products[p].2));")
            }
            sql += "INSERT INTO orders VALUES (\(i), \(1 + rng.next(480)), '\(statuses[rng.next(statuses.count)])', \(String(format: "%.2f", total)), datetime('2025-03-01', '+\(rng.next(620)) days', '+\(rng.next(86400)) seconds'));\n"
            sql += items.joined(separator: "\n") + "\n"
        }
        sql += "INSERT INTO audit_log VALUES (datetime('now'), 'Demo database created');\nCOMMIT;"
        _ = try db.execute(sql)
    }
}

/// Same demo data every time.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(1, n)))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}

extension Notification.Name {
    /// Demo only: select a block of cells, for screenshots.
    static let demoSelectCells = Notification.Name("gg.maben.base.demoSelectCells")
    static let demoAdminPage = Notification.Name("gg.maben.base.demoAdminPage")
}
