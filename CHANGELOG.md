# Changelog

## 0.1 (not released yet)

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

## Next

- Self-update from GitHub Releases, as in Maben Awake and Maben Sweep
- Structure editing for the engines that are read-only there now
