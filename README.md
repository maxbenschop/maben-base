# Maben Base — Windows (Electron port)

A Windows (and cross-platform) database client, ported from [maben-base](https://github.com/maxbenschop/maben-base) for macOS. Built with Electron + React + TypeScript.

**Original macOS client:** See the [main README](https://github.com/maxbenschop/maben-base/blob/main/README.md) for the native Swift/AppKit version.

## Supported databases

| Engine | Status |
|---|---|
| PostgreSQL | ✅ Full support |
| MySQL / MariaDB | ✅ Full support |
| SQLite | ✅ Full support |
| SQL Server, Oracle, ClickHouse, DuckDB, Redis, MongoDB, Cassandra, libSQL, Snowflake, BigQuery, Cloudflare D1 | 🚧 Coming soon |

## Features

- **Connection manager** — save, group, and tag connections by environment (local / dev / staging / production)
- **Table browser** — paginated data grid with inline editing, sort by column
- **SQL editor** — CodeMirror 6, syntax highlighting, run with Ctrl+Enter
- **Object browser** — browse databases, schemas, tables and views
- **Safe modes** — Ask before writes, read-only, confirm all queries
- **TLS** — Off / Prefer / Require / Verify

## Requirements

- Node.js 20+
- npm

For SQLite support, you'll need build tools for native Node modules:
- **Windows**: Install [Build Tools for Visual Studio](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022) and Python
- **Mac/Linux**: Usually works out of the box

## Getting started

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```

The installer ends up in `dist/`.

## Architecture

```
electron/main/     — Node.js main process: database drivers, IPC handlers
electron/preload/  — Context bridge exposing the API to the renderer
src/renderer/src/  — React app (ConnectionsView, WorkspaceView, DataGrid, SQLEditor, ObjectBrowser)
```

Passwords are kept **in memory only** during the session. On Windows, a production version would store them in the Windows Credential Manager.
