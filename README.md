# Maben Base

A free database client for the Mac, for 14 engines (below). Connections on the left, your tables in tabs, every row editable and nothing written until you save. No tab or window limits, no licence key, no account, no telemetry.

Part of [Maben](https://maben.gg). Website and download: [base.maben.gg](https://base.maben.gg) (generator in `../maben/base-site-src/`), or the [latest release](https://github.com/maxbenschop/maben-base/releases/latest). It updates itself after that. Product colour: Base pink `#FF5CA8` with a black mark.

Bug reports and ideas are welcome as [issues](https://github.com/maxbenschop/maben-base/issues); `CONTRIBUTING.md` explains how to send a change and what a pull request needs.

## Engines

| Engine | How it connects | Edit rows | Edit structure | Tested here against |
|---|---|---|---|---|
| PostgreSQL | Wire protocol (TLS, SCRAM, MD5) | yes | yes | Postgres 17 |
| MySQL / MariaDB | Wire protocol (TLS, caching_sha2, native) | yes | yes | MySQL 8.4, MariaDB 11 |
| SQLite | System library | yes | yes (rebuilds when needed) | built in |
| SQL Server / Azure SQL | TDS 7.4, TLS (TDS 7) or strict TDS 8 | yes | read-only | SQL Server 2022 (plain and TLS) |
| Oracle | Your sqlplus (Instant Client) | yes | read-only | Oracle 23ai Free |
| ClickHouse | HTTP interface | yes (mutations) | read-only | ClickHouse 26 |
| DuckDB | Your duckdb tool | yes | yes | DuckDB 2.0 |
| libSQL / Turso | Hrana over HTTP | yes | yes | libsql-server |
| Cloudflare D1 | REST API, API token | yes | read-only | not tested (needs an account) |
| Snowflake | SQL API v2, access token or key pair | yes | read-only | not tested (needs an account); key-pair signing is tested |
| BigQuery | REST API, service account or gcloud | yes (with a primary key) | read-only | bigquery-emulator |
| Cassandra / ScyllaDB | CQL native protocol v4 | yes | read-only | Cassandra 5 |
| MongoDB | OP_MSG, SCRAM, mongodb+srv | yes (by _id) | read-only | MongoDB 8 |
| Redis / Valkey | RESP2 | yes (keys table) | – | Redis 7 |

MongoDB collections show as tables with a column per top-level field, and the query editor takes mongosh-style commands (`db.orders.find({...}).sort({...})`, aggregate, insert/update/delete, `runCommand`, `show dbs`, `use`). Redis shows each database's keys as a table (key, type, TTL, value; hashes, lists and sets as JSON) and the query editor takes Redis commands, one per line.

## What it does

**Connections.** Saved connections in groups, with a colour tag (local, development, staging, production). Paste a URL (postgres://, mysql://, sqlserver://, mongodb+srv://, redis://, …) to fill in the form. Passwords, SSH passwords and certificate passwords go in your Keychain.
- **SSH tunnels** through the system `ssh` (your `~/.ssh/config`, agent and jump hosts), with a key, a key with a passphrase, or a password.
- **TLS:** off, prefer, require (any certificate) or verify, with your own CA file and a client certificate (.p12) when needed.
- **Unix sockets:** a host starting with `/` (Postgres socket directory or file, MySQL socket).
- **Safe modes** per connection: off, ask before writes, ask before every query, Touch ID before writes, or read-only. Tagging a connection production turns on "ask before writes".
- **Moving connections:** export them to a file (passwords encrypted with a passphrase if you include them) and import on another Mac, or import a list of URLs.
- **Sync** through your iCloud Drive (Settings): connections, not passwords. Nothing goes through a Maben server.

**Windows.** The connections and tabs you had open come back at launch. Several connections share one window as macOS tabs (Settings). Split view (⌘\\) puts two tabs side by side.

**Server** (Postgres, MySQL): a window with running queries (stop the query or end the connection), users and permissions (create, password, grant and revoke, delete; the SQL is shown first), and live metrics with charts.

**Browse and edit.**
- Tables, views, materialized views and functions in the sidebar, each opening in a tab. Rows load 300 at a time, sorted and filtered on the server.
- Cells select like a spreadsheet: click, drag or shift-click a block, move with the arrow keys and Tab, press Return to edit. ⌘C copies the cells, and ⌘V pastes spreadsheet rows into the selected cells or as new rows.
- Changed cells turn pink, deleted rows red, new rows green. ⌘S writes everything in one transaction, and **Show SQL** shows exactly what will run. If a row changed underneath you, nothing is saved.
- Foreign keys link: an arrow in the cell (or **Open** in the row details) opens the referenced row.
- Row details pick an editor per type: JSON with Format and checking, a calendar for dates (also for SQLite's text dates), a menu for enums and CHECK (… IN …) lists, true/false for booleans, and an image preview with load and save for binary data.
- Columns can be hidden, moved and resized from the header menu, and the layout is remembered per table.
- Tables the statistics put over 500,000 rows show an estimated count first, with a **Count** button for the exact number.

**Structure.** The Structure tab edits columns (name, type, null, default, comment, primary key), indexes and foreign keys. **Review changes** shows the SQL before anything runs. Postgres and SQLite apply it in one transaction. SQLite changes it can't do in place are applied by rebuilding the table, the documented way. **New table** and **New view** use the same editor.

**Query.**
- The editor highlights SQL and completes keywords, tables and columns; after `alias.` it offers only that table's columns.
- ⌘↩ runs the statement at the cursor, ⇧⌘↩ runs everything, ⌥⌘↩ runs it in a new tab so the old results stay. Stop cancels on the server.
- **Format** (⌥⇧F) lays SQL out clause by clause. **Explain** (⌥⌘E) shows the plan, or with timings (that runs the statement, so it asks first for writes).
- `:name` parameters ask for values before running.
- Several cursors: ⌥-click adds one, ⌘D adds the next match, Esc goes back to one.
- Snippets: type a trigger (`sel`, `upd`, `cte`, …) and press Tab, then Tab through the placeholders. Edit them under Query › Snippets.
- Results can open in their own window. History and saved queries are kept per connection.
- Query results keep the first 50,000 rows by default (Settings: 200,000, 1,000,000 or all); **Load all** runs it again for every row.

**Data.**
- Export a table or a result as CSV, JSON, Excel, Markdown or SQL inserts. Export a whole database as one SQL file, an Excel workbook, or CSV or JSON per table.
- **Backup and restore** uses `pg_dump`/`pg_restore`/`psql` or `mysqldump`/`mysql` (MariaDB's own tools for MariaDB) when they're installed, and SQLite's `VACUUM INTO`.
- **Import** a CSV into a table (by column name, in one transaction), or run a SQL file statement by statement.

**Safety.** Production connections ask before saving edits, running statements that change data, or changing structure. Read-only connections never write.

**Look.** Light, dark or follow the system (View › Appearance).

## Build and run

Needs macOS 14 or later and Xcode 16 or later (Swift 5.9+). No dependencies.

```sh
./build.sh            # build "Maben Base.app" into ./build
./build.sh install    # build, copy to /Applications and open it
./build.sh demo       # open a sample shop database (SQLite); your connections aren't read or changed
swift test            # unit tests; see CONTRIBUTING.md for the tests against real servers
```

`./release.sh` builds the universal, notarized download (`dist/Maben-Base.dmg` and `.zip`), and `./publish.sh` tags it, creates the GitHub release and deploys base.maben.gg. See `CONTRIBUTING.md`.

Demo flags, for screenshots and trying things: `--demo --open=customers [--structure|--edit|--filter|--cells]`, `--demo --query="select 1" [--format|--explain]`, `--demo --palette`, `--demo --sheet=newTable|newView|backup|exportDatabase|snippets`, `--demo --appearance=light`, `--demo --connections`, `--demo --settings`, and `--demo --url=postgres://…` to try a real server without saving anything.

`base-tool` (`swift run BaseTool …`) runs SQL through the same drivers: `query <url> <sql>`, `schema <url>`, `ssh <user@host:port> <key|-> <url> <sql>`, and `format <sql>`.

Data lives in `~/Library/Application Support/Maben Base/` (connections, history and saved queries as JSON). Passwords are in the Keychain under `gg.maben.base`.

## Updates

The app updates itself from GitHub Releases (`Sources/Base/Updater.swift`), the same way Maben Awake and Maben Sweep do: at
start, every 6 hours and after waking it asks the GitHub API for the latest release, downloads `Maben-Base.zip`, and only
installs it if the app inside is signed with the Developer ID of team NJTYRVLSA8 with bundle ID `gg.maben.base`, accepted by
Gatekeeper, and has the announced version. The old app goes to the Trash. An automatic install never restarts the app while
a connection window is open: it runs when none is open, or as you quit. The Update button in Settings installs at once (it
asks first when edits are unsaved) and the open connections and tabs come back. Both switches (check, install) are on by
default, in Settings under Updates (`UserDefaults` keys `updates.autoCheck` / `updates.autoInstall`). Apart from your
databases, this is the only network request the app makes. `Base --verify-update <app> <version>` runs the same checks on
an app by hand.

## How it's built

| Part | What it is |
|---|---|
| `Sources/BaseCore` | No UI. `Postgres.swift` and `MySQL.swift` speak the wire protocols directly (text results, TLS, SCRAM-SHA-256, MD5, `caching_sha2_password`, `mysql_native_password`), `SQLite.swift` uses the system library. `Dialect.swift` quotes, builds pages, filters and the SQL for staged edits. `Design.swift` turns a table design into CREATE or ALTER statements per engine. `SQLText.swift` and `SQLTools.swift` split, tokenize and format SQL, find parameters and aliases, and expand snippets. `Formats.swift` writes Excel (a small ZIP writer), Markdown and SQL dumps, and finds pg_dump and friends. `SSHTunnel.swift`, `Store.swift` (JSON, Keychain, CSV/JSON) |
| `Sources/Base` | The app: AppKit windows with SwiftUI inside. `DataGrid.swift` is an `NSTableView` (fast with large results), `SQLEditor.swift` an `NSTextView`. `Session.swift` runs every database call on one serial queue per connection |
| `Sources/BaseTool` | Command-line access to the drivers |

Each engine has its own file in `Sources/BaseCore`: `Postgres`, `MySQL`, `SQLite`, `SQLServer` (TDS, with TDS 7 TLS through SecureTransport and strict TLS through Network.framework), `Cassandra`, `Mongo` (BSON and the mongosh syntax), `Redis`, `HTTPEngines` (ClickHouse, libSQL), `ToolEngines` (DuckDB and Oracle through their own tools), `CloudEngines` (BigQuery, Snowflake, D1, and the JWT signer). `Admin.swift` holds the server window's SQL.

Values travel as text both ways: the servers send text, and edits are written as quoted literals that the server casts to the column's type. That keeps every type (JSON, arrays, UUIDs, intervals, enums) editable without a type-by-type mapping. Binary columns show as `0x…` hex and are written back as hex literals.

Not in this version: plugins, ER diagrams, and editing structure for the engines marked read-only above.

## Licence

MIT. See `LICENSE`.
