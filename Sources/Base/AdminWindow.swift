import AppKit
import BaseCore
import Charts
import SwiftUI

/// The server window: running queries, users and permissions, and live numbers. It opens its own connection,
/// so a long query in the workspace never blocks it (and it can stop that query).
@MainActor
final class AdminModel: ObservableObject {
    enum Page: String, CaseIterable { case processes = "Processes", users = "Users", metrics = "Metrics" }

    unowned let workspace: Workspace
    private var session: Session?
    @Published var page: Page = .processes
    @Published var processes: [Admin.Process] = []
    @Published var users: [Admin.User] = []
    @Published var selectedUser: String?
    @Published var grants: [String] = []
    @Published var error: String?
    @Published var autoRefresh = true
    @Published var showIdle = false
    /// Recent readings for the charts (last 2 minutes at 2 s).
    @Published var samples: [(date: Date, values: [String: Double])] = []
    @Published var latest: Admin.Reading?
    private var previous: Admin.Reading?
    private var timer: Timer?

    init(workspace: Workspace) { self.workspace = workspace }

    var kind: DatabaseKind { workspace.session.kind }

    func start() {
        Task {
            do {
                session = try await Session.open(workspace.config, secrets: workspace.session.secrets)
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.autoRefresh else { return }
                Task { await self.refresh(quiet: true) }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        session?.close()
    }

    func run<T>(_ work: @escaping (Driver) throws -> T) async throws -> T {
        guard let session else { throw DatabaseError("Not connected yet.") }
        return try await session.run(work)
    }

    func refresh(quiet: Bool = false) async {
        do {
            switch page {
            case .processes:
                processes = try await run { try Admin.processes($0) }
            case .users:
                if !quiet || users.isEmpty { users = try await run { try Admin.users($0) } }
                if let id = selectedUser, let u = users.first(where: { $0.id == id }), !quiet {
                    grants = try await run { try Admin.grants($0, user: u) }
                }
            case .metrics:
                break
            }
            // Metrics are read on every tick so the charts have history when you open them.
            let reading = try await run { try Admin.read($0) }
            if let previous {
                let rates = Admin.rates(from: previous, to: reading)
                samples.append((reading.date, rates.merging(reading.gauges) { a, _ in a }))
                if samples.count > 60 { samples.removeFirst(samples.count - 60) }
            }
            previous = reading
            latest = reading
            if !quiet { error = nil }
        } catch {
            if !quiet { self.error = error.localizedDescription }
        }
    }

    var visibleProcesses: [Admin.Process] {
        showIdle ? processes : processes.filter { !["idle", "Sleep"].contains($0.state) && !$0.state.hasPrefix("Sleep") }
    }

    func stop(_ p: Admin.Process, endConnection: Bool) {
        Task {
            let what = endConnection ? "End connection \(p.id)" : "Stop the query of process \(p.id)"
            guard await confirm("\(what)?", detail: "\(p.user)@\(p.client) · \(p.database)\n\n\(p.query.prefix(500))",
                                button: endConnection ? "End connection" : "Stop query", window: NSApp.keyWindow) else { return }
            guard await workspace.allow(what, write: true, alreadyConfirmed: true) else { return }
            do {
                try await run { try Admin.stop($0, process: p.id, endConnection: endConnection) }
                await refresh()
            } catch {
                showError(error, in: NSApp.keyWindow)
            }
        }
    }

    /// Runs admin SQL after showing it, through the connection's safe mode.
    func apply(_ title: String, _ statements: [String]) async -> Bool {
        let shown = statements.map { $0.replacingOccurrences(of: #"(PASSWORD|IDENTIFIED BY) '(?:[^']|'')*'"#, with: "$1 '•••'", options: .regularExpression) }
        guard await confirm(title, detail: shown.map { $0 + ";" }.joined(separator: "\n"), button: "Run", destructive: false, window: NSApp.keyWindow) else { return false }
        guard await workspace.allow(shown.joined(separator: ";\n"), write: true, alreadyConfirmed: true) else { return false }
        do {
            try await run { d in for s in statements { _ = try d.execute(s) } }
            users = try await run { try Admin.users($0) }
            if let id = selectedUser, let u = users.first(where: { $0.id == id }) { grants = try await run { try Admin.grants($0, user: u) } }
            return true
        } catch {
            showError(error, in: NSApp.keyWindow)
            return false
        }
    }
}

@MainActor
final class AdminWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: AdminWindowController] = [:]
    private let model: AdminModel
    private let key: ObjectIdentifier

    static func show(for workspace: Workspace) {
        let key = ObjectIdentifier(workspace)
        if let existing = open[key] { existing.window?.makeKeyAndOrderFront(nil); return }
        let c = AdminWindowController(workspace: workspace, key: key)
        open[key] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(workspace: Workspace, key: ObjectIdentifier) {
        model = AdminModel(workspace: workspace)
        self.key = key
        let window = makeMabenWindow(size: NSSize(width: 980, height: 620), autosave: "MabenBaseAdmin")
        window.title = "Server · \(workspace.config.displayName)"
        window.minSize = NSSize(width: 700, height: 420)
        super.init(window: window)
        window.delegate = self
        window.setContent(AdminView(model: model), size: NSSize(width: 980, height: 620), autosave: "MabenBaseAdmin")
        model.start()
        NotificationCenter.default.addObserver(forName: .demoAdminPage, object: nil, queue: .main) { [weak model] n in
            MainActor.assumeIsolated { if let raw = n.object as? String, let p = AdminModel.Page(rawValue: raw) { model?.page = p } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.open[key] = nil
    }
}

struct AdminView: View {
    @ObservedObject var model: AdminModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 64, height: 1)
                Text("Server").font(.system(size: 13, weight: .semibold)).foregroundStyle(MB.text)
                Text(model.workspace.config.displayName).font(.system(size: 12)).foregroundStyle(MB.dim).lineLimit(1)
                Spacer()
                MBSegmented(options: AdminModel.Page.allCases, selection: $model.page) { $0.rawValue }
                    .onChange(of: model.page) { _, _ in Task { await model.refresh() } }
                Spacer()
                Toggle("Live", isOn: $model.autoRefresh).toggleStyle(.checkbox).font(.system(size: 12)).help("Refresh every 2 seconds")
                MBIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            }
            .padding(.horizontal, 12).frame(height: 48).background(MB.bar)
            Hairline()
            if let error = model.error {
                ErrorPanel(message: error)
            } else {
                switch model.page {
                case .processes: ProcessesPage(model: model)
                case .users: UsersPage(model: model)
                case .metrics: MetricsPage(model: model)
                }
            }
        }
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
    }
}

private struct ProcessesPage: View {
    @ObservedObject var model: AdminModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.visibleProcesses.count) of \(model.processes.count) connection\(model.processes.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(MB.muted)
                Spacer()
                Toggle(model.kind == .mysql ? "Show sleeping" : "Show idle", isOn: $model.showIdle).toggleStyle(.checkbox).font(.system(size: 12))
            }
            .padding(.horizontal, 14).frame(height: 36)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleProcesses) { p in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(p.id).font(MB.mono).foregroundStyle(MB.dim)
                                    Text(p.user).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MB.text)
                                    Text("\(p.client) · \(p.database)").font(.system(size: 11.5)).foregroundStyle(MB.dim).lineLimit(1)
                                    MBTag(text: p.state, color: p.state.hasPrefix("active") || p.state.hasPrefix("Query") ? MB.green : MB.dim)
                                    if let s = p.seconds { Text(duration(s)).font(.system(size: 11.5)).foregroundStyle(s > 60 ? MB.orange : MB.dim).monospacedDigit() }
                                }
                                if !p.query.isEmpty {
                                    Text(p.query).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(MB.muted).lineLimit(3).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button("Stop query") { model.stop(p, endConnection: false) }.buttonStyle(.mbQuiet)
                            Button("End") { model.stop(p, endConnection: true) }.buttonStyle(.mbDanger).help("End the connection")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                    if model.visibleProcesses.isEmpty {
                        Text("Nothing is running right now.").font(.system(size: 12.5)).foregroundStyle(MB.dim).padding(30)
                    }
                }
            }
        }
    }

    private func duration(_ s: Double) -> String {
        s < 1 ? "<1 s" : s < 60 ? "\(Int(s)) s" : s < 3600 ? "\(Int(s / 60)) min" : String(format: "%.1f h", s / 3600)
    }
}

private struct UsersPage: View {
    @ObservedObject var model: AdminModel
    @State private var privileges: Set<Admin.Privilege> = [.select]
    @State private var table = ""
    @State private var container = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.users) { u in
                            HStack(spacing: 8) {
                                Image(systemName: u.superuser ? "person.badge.key.fill" : u.canLogin ? "person.fill" : "person.2")
                                    .font(.system(size: 11)).foregroundStyle(u.superuser ? MB.accentInk : MB.dim).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(u.host.map { "\(u.name)@\($0)" } ?? u.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(MB.text)
                                    Text([u.superuser ? "superuser" : nil, u.canLogin ? nil : "can't sign in (group role)", u.detail.isEmpty ? nil : u.detail]
                                        .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(MB.dim).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedUser == u.id ? MB.selected : .clear))
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedUser = u.id; Task { await model.refresh() } }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Hairline()
                HStack {
                    Button { newUser() } label: { Label("New user", systemImage: "plus") }.buttonStyle(.mbPlain)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 300).background(MB.sidebar)
            Hairline(vertical: true)
            if let u = model.users.first(where: { $0.id == model.selectedUser }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(u.host.map { "\(u.name)@\($0)" } ?? u.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                            Spacer()
                            Button("Change password…") { changePassword(u) }.buttonStyle(.mbQuiet)
                            Button("Delete user…") { drop(u) }.buttonStyle(.mbDanger)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Permissions").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                            if model.grants.isEmpty {
                                Text("No grants on tables").font(.system(size: 12)).foregroundStyle(MB.dim)
                            }
                            ForEach(model.grants, id: \.self) { g in
                                Text(g).font(.system(size: 12, design: .monospaced)).foregroundStyle(MB.text).textSelection(.enabled)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Grant or revoke").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                            HStack(spacing: 12) {
                                ForEach(Admin.Privilege.allCases, id: \.self) { p in
                                    Toggle(p == .all ? "All" : p.rawValue.capitalized, isOn: Binding(get: { privileges.contains(p) },
                                        set: { if $0 { privileges.insert(p) } else { privileges.remove(p) } })).toggleStyle(.checkbox).font(.system(size: 12))
                                }
                            }
                            HStack(spacing: 8) {
                                Text("on").font(.system(size: 12)).foregroundStyle(MB.dim)
                                MBField(placeholder: model.kind == .postgres ? "schema" : "database", text: $container, mono: true).frame(width: 150)
                                Text(".").foregroundStyle(MB.dim)
                                MBField(placeholder: "table, or empty for all tables", text: $table, mono: true)
                            }
                            HStack {
                                Spacer()
                                Button("Revoke") { change(u, revoke: true) }.buttonStyle(.mbQuiet).disabled(privileges.isEmpty || container.isEmpty)
                                Button("Grant") { change(u, revoke: false) }.buttonStyle(.mbPrimary).disabled(privileges.isEmpty || container.isEmpty)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
                    }
                    .padding(18)
                }
                .onAppear { container = model.kind == .postgres ? (model.workspace.schema ?? "public") : (model.workspace.database ?? "") }
            } else {
                Text("Pick a user").font(.system(size: 12.5)).foregroundStyle(MB.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func change(_ u: Admin.User, revoke: Bool) {
        let sql = Admin.grant(model.kind, revoke: revoke, privileges: Array(privileges).sorted { $0.rawValue < $1.rawValue }, user: u,
                              container: container, table: table.isEmpty ? nil : table)
        Task { _ = await model.apply(revoke ? "Revoke from \(u.name)?" : "Grant to \(u.name)?", [sql]) }
    }

    private func newUser() {
        guard let name = ask("New user", detail: model.kind == .mysql ? "The user name; it may sign in from any host (%)." : "The role name; it can sign in with a password.",
                             placeholder: "name"), !name.isEmpty,
              let password = ask("Password for \(name)", detail: "Shown as ••• in the SQL that runs.", secure: true), !password.isEmpty else { return }
        Task { _ = await model.apply("Create user \(name)?", Admin.createUser(model.kind, name: name, host: "%", password: password, superuser: false)) }
    }

    private func changePassword(_ u: Admin.User) {
        guard let password = ask("New password for \(u.name)", detail: "", secure: true), !password.isEmpty else { return }
        Task { _ = await model.apply("Change the password of \(u.name)?", [Admin.setPassword(model.kind, user: u, password: password)]) }
    }

    private func drop(_ u: Admin.User) {
        Task {
            let note = model.kind == .postgres ? "\n\nWhat the role owns in this database becomes yours first." : ""
            guard await confirm("Delete \(u.name)?", detail: "It can't sign in any more.\(note)", button: "Delete", window: NSApp.keyWindow) else { return }
            if await model.apply("Delete \(u.name)?", Admin.dropUser(model.kind, user: u)) { model.selectedUser = nil }
        }
    }
}

private struct MetricsPage: View {
    @ObservedObject var model: AdminModel

    var body: some View {
        ScrollView {
            let g = model.latest?.gauges ?? [:]
            let rate = model.samples.last?.values ?? [:]
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    tile("Connections", "\(Int(g["connections"] ?? 0)) of \(Int(g["maxConnections"] ?? 0))", key: "connections")
                    tile("Running now", "\(Int(g["active"] ?? 0))", key: "active")
                    if model.kind == .postgres {
                        tile("Transactions / s", format(rate["transactions"]), key: "transactions")
                        tile("Waiting for locks", "\(Int(g["waitingLocks"] ?? 0))", key: "waitingLocks")
                        tile("Longest query", "\(Int(g["longestQuery"] ?? 0)) s", key: "longestQuery")
                        tile("Database size", ByteCountFormatter.string(fromByteCount: Int64(g["databaseSize"] ?? 0), countStyle: .file), key: nil)
                    } else {
                        tile("Queries / s", format(rate["queries"]), key: "queries")
                        tile("Slow queries / s", format(rate["slowQueries"]), key: "slowQueries")
                        tile("Network in / s", ByteCountFormatter.string(fromByteCount: Int64(rate["bytesIn"] ?? 0), countStyle: .binary), key: "bytesIn")
                        tile("Up for", "\(Int((g["uptime"] ?? 0) / 3600)) h", key: nil)
                    }
                    tile("Rows read / s", format(rate["rowsRead"]), key: "rowsRead")
                    tile("Rows written / s", format(rate["rowsWritten"]), key: "rowsWritten")
                    tile("Cache hits", rate["cacheHitRatio"].map { String(format: "%.1f%%", $0 * 100) } ?? "—", key: "cacheHitRatio")
                }
                Text("Rates are averaged over 2 seconds; charts show the last 2 minutes.").font(.system(size: 11.5)).foregroundStyle(MB.dim)
            }
            .padding(18)
        }
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    private func tile(_ title: String, _ value: String, key: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(MB.dim)
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(MB.text).monospacedDigit().lineLimit(1)
            if let key {
                Chart(Array(model.samples.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("Time", s.date), y: .value(title, s.values[key] ?? 0))
                        .foregroundStyle(MB.accent)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: 0...max(1, (model.samples.compactMap { $0.values[key] }.max() ?? 1) * 1.15))
                .frame(height: 34)
            } else {
                Color.clear.frame(height: 34)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: MB.radius).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: MB.radius).strokeBorder(MB.line))
    }
}
