import BaseCore
import Foundation

// base-tool query <url> <sql>    runs SQL and prints the results
// base-tool schema <url>         prints databases, schemas, tables and the columns of each table
// base-tool ssh <user@host:port> <key file or -> <url> <sql>   runs SQL through an SSH tunnel; the URL's host is as seen from the SSH server
let args = CommandLine.arguments
if args.count == 3, args[1] == "format" {
    print(SQLFormatter.format(args[2]), terminator: "")
    exit(0)
}
guard args.count >= 3 else {
    print("usage: base-tool query <url> <sql> | base-tool schema <url>")
    exit(2)
}

var config = ConnectionConfig()
let (ok, password) = config.apply(url: args[2])
guard ok || args[1] == "ssh" else { print("Not a database URL: \(args[2])"); exit(2) }

var tunnel: SSHTunnel?
if args[1] == "ssh", args.count >= 6 {
    config = ConnectionConfig()
    let parsed = config.apply(url: args[4])
    let target = args[2]
    let at = target.firstIndex(of: "@")
    config.sshUser = at.map { String(target[..<$0]) } ?? ""
    let hostPort = at.map { String(target[target.index(after: $0)...]) } ?? target
    let parts = hostPort.split(separator: ":")
    config.sshHost = String(parts[0])
    config.sshPort = parts.count > 1 ? Int(parts[1]) ?? 22 : 22
    // <key file>, "-" for the agent, or "password:<secret>" / "passphrase:<secret>:<key file>"
    var secret: String?
    if args[3].hasPrefix("password:") {
        config.sshUsePassword = true
        secret = String(args[3].dropFirst(9))
    } else if args[3].hasPrefix("passphrase:") {
        let parts = args[3].split(separator: ":", maxSplits: 2).map(String.init)
        secret = parts[1]
        config.sshKeyPath = parts[2]
    } else {
        config.sshKeyPath = args[3] == "-" ? "" : args[3]
    }
    config.sshEnabled = true
    do {
        tunnel = try SSHTunnel(config: config, secret: secret)
        print("tunnel: 127.0.0.1:\(tunnel!.localPort) → \(config.host):\(config.port) via \(config.sshHost)")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    _ = parsed
}

do {
    let certPassword = URLComponents(string: args[args[1] == "ssh" ? 4 : 2])?.queryItems?.first { $0.name == "sslpassword" }?.value
    let driver = try Connector.open(config, password: args[1] == "ssh" ? config.apply(url: args[4]).password : password,
                                    host: tunnel.map { _ in "127.0.0.1" }, port: tunnel?.localPort, certificatePassword: certPassword)
    defer { driver.close() }
    print("connected: \(driver.kind.title) \(driver.serverVersion), database \(driver.currentDatabase ?? "-")")
    switch args[1] {
    case "query", "ssh":
        let start = Date()
        for result in try driver.execute(args[1] == "ssh" ? args[5] : args[3]) {
            if result.hasRows {
                print(result.columns.map { "\($0.name):\($0.typeName)\($0.isBinary ? "*" : "")" }.joined(separator: " | "))
                for row in result.rows { print(row.map { $0 ?? "NULL" }.joined(separator: " | ")) }
            }
            print("-- \(result.message ?? "") \(result.affectedRows.map { "(\($0) affected)" } ?? "")")
        }
        print("-- \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    case "schema":
        print("databases: \(try driver.databases().joined(separator: ", "))")
        let schemas = try driver.schemas()
        print("schemas: \(schemas.joined(separator: ", "))")
        for schema in schemas.isEmpty ? [nil] : schemas.map(Optional.some) {
            for object in try driver.objects(schema: schema) {
                print("\(object.kind.rawValue) \(object.schema.map { "\($0)." } ?? "")\(object.name)")
                guard object.kind == .table else { continue }
                for c in try driver.columns(of: object.table) {
                    print("   \(c.isPrimaryKey ? "*" : " ") \(c.name) \(c.type)\(c.nullable ? "" : " not null")\(c.defaultValue.map { " = \($0)" } ?? "")")
                }
                for i in try driver.indexes(of: object.table) { print("   idx \(i.name) (\(i.columns.joined(separator: ", ")))\(i.unique ? " unique" : "")") }
            }
        }
    default:
        print("unknown command \(args[1])")
    }
} catch {
    print("error: \(error.localizedDescription)")
    if let e = error as? DatabaseError, let code = e.code { print("code: \(code)") }
    exit(1)
}
