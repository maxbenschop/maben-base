export type DatabaseKind =
  | 'postgres' | 'mysql' | 'sqlite' | 'sqlserver' | 'oracle'
  | 'clickhouse' | 'duckdb' | 'libsql' | 'd1' | 'snowflake'
  | 'bigquery' | 'cassandra' | 'mongodb' | 'redis'

export type TLS = 'off' | 'prefer' | 'require' | 'verify'
export type Environment = 'local' | 'development' | 'staging' | 'production'
export type SafeMode = 'off' | 'confirmWrites' | 'confirmAll' | 'readOnly'

export interface ConnectionConfig {
  id: string
  name: string
  group: string
  kind: DatabaseKind
  environment: Environment
  host: string
  port: number
  user: string
  database: string
  tls: TLS
  filePath: string
  safeMode: SafeMode
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

export function defaultConnection(kind: DatabaseKind = 'postgres'): ConnectionConfig {
  return {
    id: crypto.randomUUID(),
    name: '',
    group: '',
    kind,
    environment: 'local',
    host: '127.0.0.1',
    port: defaultPort(kind),
    user: kind === 'postgres' ? (navigator.userAgent.includes('Windows') ? '' : '') : kind === 'mysql' ? 'root' : '',
    database: '',
    tls: kind === 'sqlite' ? 'off' : 'prefer',
    filePath: '',
    safeMode: 'off',
    caFile: '',
    clientCertFile: '',
    sshEnabled: false,
    sshHost: '',
    sshPort: 22,
    sshUser: '',
    sshKeyPath: '',
    sshUsePassword: false,
    options: {},
  }
}

export function defaultPort(kind: DatabaseKind): number {
  const ports: Partial<Record<DatabaseKind, number>> = {
    postgres: 5432, mysql: 3306, sqlserver: 1433, oracle: 1521,
    clickhouse: 8123, libsql: 8080, cassandra: 9042, mongodb: 27017, redis: 6379,
  }
  return ports[kind] ?? 0
}

export function kindTitle(kind: DatabaseKind): string {
  const titles: Record<DatabaseKind, string> = {
    postgres: 'PostgreSQL', mysql: 'MySQL / MariaDB', sqlite: 'SQLite',
    sqlserver: 'SQL Server', oracle: 'Oracle', clickhouse: 'ClickHouse',
    duckdb: 'DuckDB', libsql: 'libSQL / Turso', d1: 'Cloudflare D1',
    snowflake: 'Snowflake', bigquery: 'BigQuery', cassandra: 'Cassandra / ScyllaDB',
    mongodb: 'MongoDB', redis: 'Redis / Valkey',
  }
  return titles[kind]
}

export function kindShort(kind: DatabaseKind): string {
  const s: Record<DatabaseKind, string> = {
    postgres: 'Postgres', mysql: 'MySQL', sqlite: 'SQLite', sqlserver: 'SQL Server',
    oracle: 'Oracle', clickhouse: 'ClickHouse', duckdb: 'DuckDB', libsql: 'libSQL',
    d1: 'D1', snowflake: 'Snowflake', bigquery: 'BigQuery', cassandra: 'Cassandra',
    mongodb: 'MongoDB', redis: 'Redis',
  }
  return s[kind]
}

export const ALL_KINDS: DatabaseKind[] = [
  'postgres', 'mysql', 'sqlite', 'sqlserver', 'oracle', 'clickhouse',
  'duckdb', 'libsql', 'd1', 'snowflake', 'bigquery', 'cassandra', 'mongodb', 'redis',
]

export const SUPPORTED_KINDS: DatabaseKind[] = ['postgres', 'mysql', 'sqlite']

export function isFileKind(kind: DatabaseKind): boolean {
  return kind === 'sqlite' || kind === 'duckdb'
}

export function isCloudKind(kind: DatabaseKind): boolean {
  return kind === 'd1' || kind === 'snowflake' || kind === 'bigquery'
}

export function connectionSummary(c: ConnectionConfig): string {
  if (c.kind === 'sqlite') return c.filePath || '(in-memory)'
  let s = c.user ? `${c.user}@` : ''
  s += `${c.host}:${c.port}`
  if (c.database) s += `/${c.database}`
  return s
}

export function connectionDisplayName(c: ConnectionConfig): string {
  if (c.name) return c.name
  if (c.kind === 'sqlite') return c.filePath.split(/[\\/]/).pop() || 'SQLite'
  return c.database || c.host || kindShort(c.kind)
}

export function envColor(env: Environment): string {
  return { local: '#555', development: '#3b82f6', staging: '#f97316', production: '#ef4444' }[env]
}

export function tlsTitle(tls: TLS): string {
  return { off: 'Off', prefer: 'Prefer', require: 'Require', verify: 'Verify' }[tls]
}

export interface QueryResult {
  columns: { name: string; typeName: string }[]
  rows: (string | null)[][]
  affectedRows?: number
  message?: string
  truncated: boolean
}

export interface DBObject {
  schema?: string
  name: string
  kind: 'table' | 'view'
}

export interface ColumnInfo {
  name: string
  type: string
  nullable: boolean
  defaultValue?: string
  isPrimaryKey: boolean
}

export interface PageResult {
  columns: { name: string; typeName: string }[]
  rows: (string | null)[][]
  total: number
  truncated: boolean
}

// The object the renderer passes to workspace for an open connection
export interface ActiveSession {
  sessionId: string
  config: ConnectionConfig
  password: string
  serverVersion: string
}
