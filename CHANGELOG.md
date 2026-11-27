# Changelog

Every release of Maben Base. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, and base.maben.gg/changelog is built from this file.

## 0.2.3 · 27 November 2026

Security fixes from a review of the whole app.

- TLS Verify checks the server's certificate, and that it is for the right host, before anything is sent. Before, a Redis password or a MySQL sign-in could reach a server that hadn't been checked yet
- New connections to a server out on the internet start on TLS Verify; this Mac and private networks keep Prefer (Off for Redis, MongoDB, Cassandra, ClickHouse and libSQL, which are plain there). Saved connections keep the mode they have
- TLS Prefer no longer goes on without encryption to a server out on the internet: it stops and tells you to choose Off if that is what you want. A password the server can read (Postgres password sign-in, MySQL clear password and its key exchange, SQL Server, Cassandra) is never sent unencrypted there
- ClickHouse, libSQL and the other engines reached over HTTPS check the certificate unless you chose TLS Require, and don't send a password or token to a plain http:// address out on the internet unless TLS is Off
- SQL Server with TLS Require or Verify insists on encrypting the whole connection, not only the sign-in
- A pasted URL means what its own tools mean: rediss://, mongodb+srv://, turso:// and libsql:// check the certificate; sslmode=require encrypts without checking it. Each TLS mode says what it does under the picker
- Read-only, "Ask before writes" and Touch ID now go by what is known to only read, so CALL, MERGE, COPY, SELECT … INTO, writes inside WITH, and every Redis and MongoDB write command are caught. Read-only connections also ask Postgres, MySQL and SQLite to refuse writes. Explain with timings follows the same rule
- Oracle: a value or a table name from the database can no longer run a command through sqlplus. It starts in restricted mode, and line breaks in values are written as CHR(10)
- DuckDB: lines that run the tool's own commands (.shell, .read, …) only work when you type them in the query editor, not from an imported SQL file or from data
- Redis and MongoDB edits are sent as values, so a key with a line break or an _id that looks like a query can't change what is run
- Values with a backslash are written safely for Snowflake and Postgres, and names with a backslash for ClickHouse and BigQuery
- The path to sqlplus or duckdb is set in the connection's editor only, and stays on this Mac. It is no longer read from a pasted URL, a connections file or iCloud sync (if you had set one, set it again), and connections with line breaks in their settings are refused
- A saved password is only used for the host, port and user it was saved for. If a connection changes through sync or an imported file, the app asks for the password again instead of sending it to the new server. Passwords you already saved keep working
- CSV files have a "Protect against spreadsheet formulas" option, on until you turn it off, that keeps Excel and Numbers from running a value that starts with =, +, - or @. Numbers are left alone
- Exporting CSV or JSON per table can't write outside the folder you chose, whatever a table is called, and a table name can't add statements to a SQL export
- Backup and restore pass the database to pg_dump and mysqldump so that its name can't be read as an option or as another server
- The server window quotes MySQL account names, so an account with a quote in its name can't change the statement
- SSH tunnels: a host or user that starts with a hyphen is refused, and the app only uses the local port once its own ssh is the one listening on it
- A broken or hostile server can no longer stop the app with a malformed reply: every driver checks lengths and counts, and gives an error instead
- Updates: the download must come from this repository's releases on github.com and be a notarized Maben app. The new app is checked where it lands, then swapped in so that the app is never missing if something fails; with an administrator password, root checks its own copy. Links in release notes only work over https
- `--url=`, `--also=`, `--query=` and `--verify-update` only work in development builds now, and the released app no longer reads `MABEN_BASE_DATA`

## 0.2.2 · 20 November 2026

- Wide tables scroll smoothly: the grid does about 25 times less work per frame (measured on 43 columns), also with hundreds of thousands of rows loaded
- The demo (`--demo`) no longer asks the Keychain for a saved connection's password when it starts

## 0.2.1 · 19 November 2026

- New query tabs take the lowest free number, so closing "Query 2" and opening a new one gives "Query 2" again instead of counting up

## 0.2 · 19 November 2026

- The app icon stays pink with the Dark icon style on macOS 26 and later (it showed as a black square), with a pink mark on black in Dark and its own tinted and clear versions

## 0.1 · 12 November 2026

The first version.

- Postgres, MySQL/MariaDB and SQLite, with drivers written for this app (no dependencies)
- Connections window with groups, environment tags, URL paste, Keychain passwords, TLS modes and SSH tunnels
- Tables in tabs with server-side paging, sorting and filters, a row inspector and a structure view
- Staged edits (change, add, duplicate, delete rows) saved in one transaction, with the SQL shown first
- SQL editor with highlighting, completion, run statement or all, stop, several results, history and saved queries
- ⌘P open anything, ⌘K switch database, a schema picker for Postgres
- CSV, JSON and SQL export, and CSV import
- Production connections ask before writing, and read-only connections never write
- Structure editing (columns, primary key, indexes, foreign keys) with a SQL review; new tables and views
- Foreign key links to the referenced row
- Light, dark and system appearance
- Explain, with or without timings
- Backup and restore with the engines' own tools; whole-database export as SQL, Excel, CSV or JSON; SQL file import
- Excel and Markdown export, and copying cells as CSV, JSON, Markdown or SQL
- Editors per type in the row details: JSON, dates, enums, booleans, binary data with image preview
- Spreadsheet-style cell selection, paste from spreadsheets, and remembered column layouts
- Estimated row counts for very large tables
- Format SQL, :name parameters, several cursors, snippets, run in new tab, results in their own window, and column completion for table aliases

- Engines: SQL Server and Azure SQL, Oracle, ClickHouse, DuckDB, libSQL/Turso, Cloudflare D1, Snowflake, BigQuery, Cassandra/ScyllaDB, MongoDB, Redis/Valkey
- Reopens the last connections and tabs; connections as window tabs; split view
- Query results past 50,000 rows (Settings), and Load all
- Safe modes per connection, including Touch ID before writes
- Connection files to move connections between Macs (passwords encrypted with a passphrase), import from URLs, and sync through iCloud Drive
- SSH passwords and key passphrases, TLS client certificates and CA files, Unix sockets
- Server window for Postgres and MySQL: running queries, users and permissions, live metrics
- Updates itself from GitHub Releases, as Maben Awake and Maben Sweep do: it checks at start and every 6 hours, verifies the Maben signature and Apple's notarization, and installs when no connection is open or as you quit. Both switches are in Settings

## Next

- Structure editing for the engines that are read-only there now
