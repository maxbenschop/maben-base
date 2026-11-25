import { app, BrowserWindow, ipcMain, shell } from 'electron'
import { join } from 'path'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs'
import { is } from '@electron-toolkit/utils'
import { randomUUID } from 'crypto'

// ── Types shared with renderer ──────────────────────────────────────────────

interface ConnectionConfig {
  id: string
  name: string
  group: string
  kind: string
  environment: string
  host: string
  port: number
  user: string
  database: string
  tls: string
  filePath: string
  safeMode: string
  caFile: string
  clientCertFile: string
  sshEnabled: boolean
  sshHost: string
  sshPort: number
  sshUser: string
  sshKeyPath: string
  sshUsePassword: boolean
  options: Record<string, string>
}

interface QueryResult {
  columns: { name: string; typeName: string }[]
  rows: (string | null)[][]
  affectedRows?: number
  message?: string
  truncated: boolean
}

interface DBObject {
  schema?: string
  name: string
  kind: string
}

interface ColumnInfo {
  name: string
  type: string
  nullable: boolean
  defaultValue?: string
  isPrimaryKey: boolean
}

// ── Storage ─────────────────────────────────────────────────────────────────

function getStorePath(): string {
  const dir = app.getPath('userData')
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
  return join(dir, 'connections.json')
}

function loadConnections(): ConnectionConfig[] {
  try {
    const p = getStorePath()
    if (!existsSync(p)) return []
    return JSON.parse(readFileSync(p, 'utf-8'))
  } catch {
    return []
  }
}

function saveConnections(list: ConnectionConfig[]): void {
  writeFileSync(getStorePath(), JSON.stringify(list, null, 2))
}

// ── Password storage (in-memory for session; real app would use Windows Credential Manager) ──

const passwords = new Map<string, string>()

// ── Database sessions ────────────────────────────────────────────────────────

interface SqlJsDB {
  run(sql: string, params?: unknown[]): SqlJsDB
  exec(sql: string): Array<{ columns: string[]; values: unknown[][] }>
  export(): Uint8Array
  close(): void
}

interface Session {
  id: string
  kind: string
  pgClient?: import('pg').Client
  mysqlConn?: import('mysql2/promise').Connection
  sqliteDb?: SqlJsDB
  sqliteFilePath?: string
  currentDatabase: string
}

const sessions = new Map<string, Session>()

// ── Helpers ──────────────────────────────────────────────────────────────────

function tlsOpts(config: ConnectionConfig) {
  if (config.tls === 'off') return false
  if (config.tls === 'prefer') return { rejectUnauthorized: false }
  if (config.tls === 'require') return { rejectUnauthorized: false }
  return { rejectUnauthorized: true }
}

async function openPostgres(config: ConnectionConfig, password: string, database?: string): Promise<import('pg').Client> {
  const { Client } = await import('pg')
  const base = {
    host: config.host,
    port: config.port,
    user: config.user || undefined,
    password: password || undefined,
    database: database || config.database || config.user || 'postgres',
    connectionTimeoutMillis: 10000,
  }

  if (config.tls === 'off') {
    const client = new Client({ ...base, ssl: false })
    await client.connect()
    return client
  }

  if (config.tls === 'prefer') {
    // Try TLS first; if the server doesn't support it, fall back to plaintext.
    try {
      const client = new Client({ ...base, ssl: { rejectUnauthorized: false } })
      await client.connect()
      return client
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      if (msg.toLowerCase().includes('ssl') || msg.includes('ECONNRESET')) {
        const client = new Client({ ...base, ssl: false })
        await client.connect()
        return client
      }
      throw e
    }
  }

  // require / verify
  const ssl = config.tls === 'verify' ? { rejectUnauthorized: true } : { rejectUnauthorized: false }
  const client = new Client({ ...base, ssl })
  await client.connect()
  return client
}

async function openMySQL(config: ConnectionConfig, password: string, database?: string): Promise<import('mysql2/promise').Connection> {
  const mysql = await import('mysql2/promise')
  const ssl = tlsOpts(config)
  const conn = await mysql.createConnection({
    host: config.host,
    port: config.port,
    user: config.user || undefined,
    password: password || undefined,
    database: database || config.database || undefined,
    ssl: ssl ? {} : undefined,
    connectTimeout: 10000,
    multipleStatements: true,
  })
  return conn
}

async function openSQLite(filePath: string): Promise<SqlJsDB> {
  const initSqlJs = (await import('sql.js')).default
  const SQL = await initSqlJs()
  if (filePath && existsSync(filePath)) {
    const fileBuffer = readFileSync(filePath)
    return new SQL.Database(fileBuffer) as unknown as SqlJsDB
  }
  return new SQL.Database() as unknown as SqlJsDB
}

// ── IPC Handlers ─────────────────────────────────────────────────────────────

function setupIPC(): void {
  // Connection management
  ipcMain.handle('connections:list', () => loadConnections())

  ipcMain.handle('connections:save', (_, config: ConnectionConfig, password: string) => {
    const list = loadConnections()
    passwords.set(config.id, password)
    const idx = list.findIndex(c => c.id === config.id)
    if (idx >= 0) list[idx] = config
    else list.push(config)
    saveConnections(list)
  })

  ipcMain.handle('connections:delete', (_, id: string) => {
    const list = loadConnections().filter(c => c.id !== id)
    saveConnections(list)
    passwords.delete(id)
  })

  ipcMain.handle('connections:getPassword', (_, id: string) => passwords.get(id) ?? '')
  ipcMain.handle('connections:setPassword', (_, id: string, pw: string) => { passwords.set(id, pw) })

  // Connect / disconnect
  ipcMain.handle('db:connect', async (_, config: ConnectionConfig, password: string) => {
    const sessionId = randomUUID()
    const session: Session = { id: sessionId, kind: config.kind, currentDatabase: config.database || '' }

    if (config.kind === 'postgres') {
      session.pgClient = await openPostgres(config, password)
      session.currentDatabase = config.database || config.user || 'postgres'
    } else if (config.kind === 'mysql') {
      session.mysqlConn = await openMySQL(config, password)
      session.currentDatabase = config.database || ''
    } else if (config.kind === 'sqlite') {
      session.sqliteDb = await openSQLite(config.filePath)
      session.sqliteFilePath = config.filePath
      session.currentDatabase = config.filePath || ':memory:'
    } else {
      throw new Error(`${config.kind} is not yet supported in the Windows client. Coming soon!`)
    }

    sessions.set(sessionId, session)
    return sessionId
  })

  ipcMain.handle('db:disconnect', (_, sessionId: string) => {
    const s = sessions.get(sessionId)
    if (!s) return
    s.pgClient?.end().catch(() => {})
    s.mysqlConn?.end().catch(() => {})
    s.sqliteDb?.close()
    sessions.delete(sessionId)
  })

  ipcMain.handle('db:serverVersion', async (_, sessionId: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    if (s.pgClient) {
      const r = await s.pgClient.query('SELECT version()')
      return (r.rows[0]?.version as string)?.split(' ').slice(0, 2).join(' ') ?? ''
    }
    if (s.mysqlConn) {
      const [rows] = await s.mysqlConn.query('SELECT VERSION() AS v')
      return 'MySQL ' + (rows as { v: string }[])[0]?.v
    }
    if (s.sqliteDb) {
      const r = s.sqliteDb.exec('SELECT sqlite_version()')
      return 'SQLite ' + (r[0]?.values[0]?.[0] ?? '')
    }
    return ''
  })

  // Test connection (doesn't save a session)
  ipcMain.handle('db:test', async (_, config: ConnectionConfig, password: string) => {
    try {
      if (config.kind === 'postgres') {
        const client = await openPostgres(config, password)
        const r = await client.query('SELECT version()')
        await client.end()
        return { ok: true, message: 'Connected · ' + ((r.rows[0]?.version as string)?.split(' ').slice(0, 2).join(' ') ?? '') }
      }
      if (config.kind === 'mysql') {
        const conn = await openMySQL(config, password)
        const [rows] = await conn.query('SELECT VERSION() AS v')
        await conn.end()
        return { ok: true, message: 'Connected · MySQL ' + (rows as { v: string }[])[0]?.v }
      }
      if (config.kind === 'sqlite') {
        const db = await openSQLite(config.filePath)
        const r = db.exec('SELECT sqlite_version()')
        const v = r[0]?.values[0]?.[0]
        db.close()
        return { ok: true, message: `Connected · SQLite ${v}` }
      }
      return { ok: false, message: `${config.kind} testing is not yet supported.` }
    } catch (e: unknown) {
      return { ok: false, message: e instanceof Error ? e.message : String(e) }
    }
  })

  // Execute SQL
  ipcMain.handle('db:execute', async (_, sessionId: string, sql: string, rowLimit = 1000) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')

    const results: QueryResult[] = []

    if (s.pgClient) {
      const statements = sql.split(/;\s*(?=\S)/).map(t => t.trim()).filter(Boolean)
      for (const stmt of statements) {
        const r = await s.pgClient.query({ text: stmt, rowMode: 'array' })
        const columns = r.fields.map(f => ({ name: f.name, typeName: pgTypeName(f.dataTypeID) }))
        const truncated = r.rows.length > rowLimit
        const rows = (truncated ? r.rows.slice(0, rowLimit) : r.rows).map(row =>
          row.map((v: unknown) => v === null ? null : String(v))
        )
        results.push({ columns, rows, affectedRows: r.rowCount ?? undefined, message: r.command, truncated })
      }
    } else if (s.mysqlConn) {
      const [rows, fields] = await s.mysqlConn.query({ sql, rowsAsArray: true }) as [unknown[][], import('mysql2').FieldPacket[]]
      if (Array.isArray(rows) && fields) {
        const columns = fields.map(f => ({ name: f.name, typeName: f.type?.toString() ?? '' }))
        const truncated = rows.length > rowLimit
        const sliced = truncated ? rows.slice(0, rowLimit) : rows
        const resultRows = sliced.map(row => (row as unknown[]).map(v => v === null ? null : String(v)))
        results.push({ columns, rows: resultRows, truncated })
      } else {
        const info = rows as { affectedRows?: number }
        results.push({ columns: [], rows: [], affectedRows: info.affectedRows, truncated: false })
      }
    } else if (s.sqliteDb) {
      const statements = sql.split(/;\s*(?=\S)/).map(t => t.trim()).filter(Boolean)
      for (const stmt of statements) {
        try {
          const r = s.sqliteDb.exec(stmt)
          if (r.length > 0 && r[0].columns.length > 0) {
            const columns = r[0].columns.map(name => ({ name, typeName: '' }))
            const truncated = r[0].values.length > rowLimit
            const rows = (truncated ? r[0].values.slice(0, rowLimit) : r[0].values)
              .map(row => row.map((v: unknown) => v === null ? null : String(v)))
            results.push({ columns, rows, truncated })
          } else {
            results.push({ columns: [], rows: [], truncated: false })
          }
        } catch (e: unknown) {
          throw new Error(e instanceof Error ? e.message : String(e))
        }
      }
    }

    return results
  })

  // List databases
  ipcMain.handle('db:databases', async (_, sessionId: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    if (s.pgClient) {
      const r = await s.pgClient.query("SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
      return r.rows.map(row => row.datname as string)
    }
    if (s.mysqlConn) {
      const [rows] = await s.mysqlConn.query('SHOW DATABASES')
      return (rows as { Database: string }[]).map(r => r.Database)
    }
    if (s.sqliteDb) return [s.currentDatabase || ':memory:']
    return []
  })

  ipcMain.handle('db:useDatabase', async (_, sessionId: string, dbName: string, config: ConnectionConfig, password: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    if (s.pgClient) {
      await s.pgClient.end().catch(() => {})
      s.pgClient = await openPostgres(config, password, dbName)
      s.currentDatabase = dbName
    } else if (s.mysqlConn) {
      await s.mysqlConn.query(`USE ${quoteIdent(dbName, 'mysql')}`)
      s.currentDatabase = dbName
    }
  })

  ipcMain.handle('db:currentDatabase', (_, sessionId: string) => {
    return sessions.get(sessionId)?.currentDatabase ?? ''
  })

  // List schemas
  ipcMain.handle('db:schemas', async (_, sessionId: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    if (s.pgClient) {
      const r = await s.pgClient.query("SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast') ORDER BY schema_name")
      return r.rows.map(r => r.schema_name as string)
    }
    return ['public']
  })

  // List objects (tables, views)
  ipcMain.handle('db:objects', async (_, sessionId: string, schema?: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    const objects: DBObject[] = []

    if (s.pgClient) {
      const sch = schema || 'public'
      const r = await s.pgClient.query(`
        SELECT table_name, table_type, table_schema
        FROM information_schema.tables
        WHERE table_schema = $1
        ORDER BY table_type, table_name
      `, [sch])
      for (const row of r.rows) {
        objects.push({
          schema: row.table_schema as string,
          name: row.table_name as string,
          kind: row.table_type === 'VIEW' ? 'view' : 'table'
        })
      }
    } else if (s.mysqlConn) {
      const db = s.currentDatabase
      if (!db) return objects
      const [rows] = await s.mysqlConn.query<import('mysql2').RowDataPacket[]>(`
        SELECT TABLE_NAME as name, TABLE_TYPE as type
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ?
        ORDER BY TABLE_TYPE, TABLE_NAME
      `, [db])
      for (const row of rows) {
        objects.push({ name: row.name as string, kind: row.type === 'VIEW' ? 'view' : 'table' })
      }
    } else if (s.sqliteDb) {
      const r = s.sqliteDb.exec("SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name")
      for (const row of (r[0]?.values ?? [])) {
        objects.push({ name: String(row[0]), kind: String(row[1]) as 'table' | 'view' })
      }
    }

    return objects
  })

  // Column info
  ipcMain.handle('db:columns', async (_, sessionId: string, tableName: string, schema?: string) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    const columns: ColumnInfo[] = []

    if (s.pgClient) {
      const sch = schema || 'public'
      const r = await s.pgClient.query(`
        SELECT
          c.column_name, c.data_type, c.is_nullable, c.column_default,
          EXISTS(
            SELECT 1 FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = $1 AND tc.table_name = $2 AND kcu.column_name = c.column_name
          ) AS is_pk
        FROM information_schema.columns c
        WHERE c.table_schema = $1 AND c.table_name = $2
        ORDER BY c.ordinal_position
      `, [sch, tableName])
      for (const row of r.rows) {
        columns.push({
          name: row.column_name as string,
          type: row.data_type as string,
          nullable: row.is_nullable === 'YES',
          defaultValue: row.column_default as string | undefined,
          isPrimaryKey: row.is_pk as boolean
        })
      }
    } else if (s.mysqlConn) {
      const db = s.currentDatabase
      const [rows] = await s.mysqlConn.query<import('mysql2').RowDataPacket[]>(`
        SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
      `, [db, tableName])
      for (const row of rows) {
        columns.push({
          name: row.COLUMN_NAME as string,
          type: row.DATA_TYPE as string,
          nullable: row.IS_NULLABLE === 'YES',
          defaultValue: row.COLUMN_DEFAULT as string | undefined,
          isPrimaryKey: row.COLUMN_KEY === 'PRI'
        })
      }
    } else if (s.sqliteDb) {
      const r = s.sqliteDb.exec(`PRAGMA table_info("${tableName.replace(/"/g, '""')}")`)
      // PRAGMA table_info cols: cid, name, type, notnull, dflt_value, pk
      for (const row of (r[0]?.values ?? [])) {
        columns.push({
          name: String(row[1]),
          type: String(row[2] ?? ''),
          nullable: row[3] === 0,
          defaultValue: row[4] !== null ? String(row[4]) : undefined,
          isPrimaryKey: Number(row[5]) > 0,
        })
      }
    }

    return columns
  })

  // Fetch a page of rows from a table
  ipcMain.handle('db:fetchPage', async (_, sessionId: string, tableName: string, schema: string | null, page: number, pageSize: number, sort?: { col: string; dir: 'asc' | 'desc' }) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')
    const offset = page * pageSize
    const orderBy = sort ? ` ORDER BY ${quoteIdent(sort.col, s.kind)} ${sort.dir.toUpperCase()}` : ''

    if (s.pgClient) {
      const tbl = schema ? `${quoteIdent(schema, 'postgres')}.${quoteIdent(tableName, 'postgres')}` : quoteIdent(tableName, 'postgres')
      const countR = await s.pgClient.query(`SELECT COUNT(*) FROM ${tbl}`)
      const total = parseInt(countR.rows[0].count as string, 10)
      const r = await s.pgClient.query({ text: `SELECT * FROM ${tbl}${orderBy} LIMIT ${pageSize} OFFSET ${offset}`, rowMode: 'array' })
      const columns = r.fields.map(f => ({ name: f.name, typeName: pgTypeName(f.dataTypeID) }))
      const rows = r.rows.map(row => (row as unknown[]).map(v => v === null ? null : String(v)))
      return { columns, rows, total, truncated: false }
    }

    if (s.mysqlConn) {
      const tbl = quoteIdent(tableName, 'mysql')
      const [countRows] = await s.mysqlConn.query<import('mysql2').RowDataPacket[]>(`SELECT COUNT(*) AS cnt FROM ${tbl}`)
      const total = countRows[0].cnt as number
      const [rows, fields] = await s.mysqlConn.query({ sql: `SELECT * FROM ${tbl}${orderBy} LIMIT ? OFFSET ?`, rowsAsArray: true }, [pageSize, offset]) as [unknown[][], import('mysql2').FieldPacket[]]
      const columns = fields.map(f => ({ name: f.name, typeName: '' }))
      const resultRows = rows.map(row => (row as unknown[]).map(v => v === null ? null : String(v)))
      return { columns, rows: resultRows, total, truncated: false }
    }

    if (s.sqliteDb) {
      const tbl = quoteIdent(tableName, 'sqlite')
      const countR = s.sqliteDb.exec(`SELECT COUNT(*) FROM ${tbl}`)
      const count = Number(countR[0]?.values[0]?.[0] ?? 0)
      const colR = s.sqliteDb.exec(`PRAGMA table_info(${tbl})`)
      const colMeta = (colR[0]?.values ?? []).map(r => ({ name: String(r[1]), typeName: String(r[2] ?? '') }))
      const dataR = s.sqliteDb.exec(`SELECT * FROM ${tbl}${orderBy} LIMIT ${pageSize} OFFSET ${offset}`)
      const colNames = dataR[0]?.columns ?? colMeta.map(c => c.name)
      const columns = colNames.map(name => ({ name, typeName: colMeta.find(c => c.name === name)?.typeName ?? '' }))
      const rows = (dataR[0]?.values ?? []).map(row => row.map((v: unknown) => v === null ? null : String(v)))
      return { columns, rows, total: count, truncated: false }
    }

    return { columns: [], rows: [], total: 0, truncated: false }
  })

  // Save row edits
  ipcMain.handle('db:saveEdits', async (_, sessionId: string, tableName: string, schema: string | null, edits: { pkColumn: string; pkValue: string; column: string; newValue: string | null }[]) => {
    const s = sessions.get(sessionId)
    if (!s) throw new Error('Session not found')

    for (const edit of edits) {
      if (s.pgClient) {
        const tbl = schema
          ? `${quoteIdent(schema, 'postgres')}.${quoteIdent(tableName, 'postgres')}`
          : quoteIdent(tableName, 'postgres')
        const col = quoteIdent(edit.column, 'postgres')
        const pk = quoteIdent(edit.pkColumn, 'postgres')
        if (edit.newValue === null) {
          await s.pgClient.query(`UPDATE ${tbl} SET ${col} = NULL WHERE ${pk} = $1`, [edit.pkValue])
        } else {
          await s.pgClient.query(`UPDATE ${tbl} SET ${col} = $1 WHERE ${pk} = $2`, [edit.newValue, edit.pkValue])
        }
      } else if (s.mysqlConn) {
        const tbl = quoteIdent(tableName, 'mysql')
        const col = quoteIdent(edit.column, 'mysql')
        const pk = quoteIdent(edit.pkColumn, 'mysql')
        await s.mysqlConn.query(`UPDATE ${tbl} SET ${col} = ? WHERE ${pk} = ?`, [edit.newValue, edit.pkValue])
      } else if (s.sqliteDb) {
        const tbl = quoteIdent(tableName, 'sqlite')
        const col = quoteIdent(edit.column, 'sqlite')
        const pk = quoteIdent(edit.pkColumn, 'sqlite')
        s.sqliteDb.run(`UPDATE ${tbl} SET ${col} = ? WHERE ${pk} = ?`, [edit.newValue, edit.pkValue])
        if (s.sqliteFilePath) writeFileSync(s.sqliteFilePath, Buffer.from(s.sqliteDb.export()))
      }
    }
  })

  // Open external links — only http/https to prevent file:// or custom-protocol abuse
  ipcMain.on('shell:openExternal', (_, url: string) => {
    try {
      const parsed = new URL(url)
      if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
        shell.openExternal(parsed.toString())
      }
    } catch { /* ignore malformed URLs */ }
  })
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function quoteIdent(name: string, kind: string): string {
  if (kind === 'mysql') return `\`${name.replace(/`/g, '``')}\``
  return `"${name.replace(/"/g, '""')}"`
}

const PG_TYPE_NAMES: Record<number, string> = {
  16: 'bool', 17: 'bytea', 20: 'int8', 21: 'int2', 23: 'int4', 25: 'text',
  114: 'json', 700: 'float4', 701: 'float8', 1082: 'date', 1083: 'time',
  1114: 'timestamp', 1184: 'timestamptz', 1700: 'numeric', 3802: 'jsonb',
}
function pgTypeName(oid: number): string { return PG_TYPE_NAMES[oid] ?? `oid:${oid}` }

// ── Window ───────────────────────────────────────────────────────────────────

function createWindow(): void {
  const win = new BrowserWindow({
    width: 1200,
    height: 780,
    minWidth: 760,
    minHeight: 520,
    backgroundColor: '#1c1c1e',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    frame: process.platform !== 'darwin',
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false,
    }
  })

  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL)
    win.webContents.openDevTools()
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  setupIPC()
  createWindow()
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow() })
})

app.on('window-all-closed', () => {
  sessions.forEach(s => {
    s.pgClient?.end().catch(() => {})
    s.mysqlConn?.end().catch(() => {})
    s.sqliteDb?.close()
  })
  if (process.platform !== 'darwin') app.quit()
})
