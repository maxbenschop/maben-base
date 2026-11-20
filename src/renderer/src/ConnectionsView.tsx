import { useState, useEffect, useCallback } from 'react'
import {
  ConnectionConfig, defaultConnection, kindTitle, connectionDisplayName, connectionSummary,
  envColor, tlsTitle, ALL_KINDS, SUPPORTED_KINDS, DatabaseKind, TLS, Environment, SafeMode, isFileKind,
  isCloudKind, defaultPort, ActiveSession,
} from './types'

declare const api: typeof import('../../../electron/preload/index').API extends { [K in keyof infer T]: T[K] } ? typeof import('../../../electron/preload/index').API : {
  listConnections: () => Promise<ConnectionConfig[]>
  saveConnection: (c: ConnectionConfig, pw: string) => Promise<void>
  deleteConnection: (id: string) => Promise<void>
  getPassword: (id: string) => Promise<string>
  connect: (c: ConnectionConfig, pw: string) => Promise<string>
  serverVersion: (sid: string) => Promise<string>
  testConnection: (c: ConnectionConfig, pw: string) => Promise<{ ok: boolean; message: string }>
}

interface Props { onConnect: (session: ActiveSession) => void }

export default function ConnectionsView({ onConnect }: Props) {
  const [connections, setConnections] = useState<ConnectionConfig[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [draft, setDraft] = useState<ConnectionConfig>(defaultConnection())
  const [password, setPassword] = useState('')
  const [filter, setFilter] = useState('')
  const [busy, setBusy] = useState('')
  const [testResult, setTestResult] = useState<{ ok: boolean; message: string } | null>(null)

  useEffect(() => {
    api.listConnections().then(list => {
      setConnections(list)
      if (list.length > 0) selectConnection(list[0].id, list)
    })
  }, [])

  async function selectConnection(id: string, list = connections) {
    setSelectedId(id)
    setTestResult(null)
    const c = list.find(x => x.id === id)
    if (c) {
      setDraft({ ...c })
      const pw = await api.getPassword(id)
      setPassword(pw)
    }
  }

  function newConnection(kind: DatabaseKind = 'postgres') {
    const c = defaultConnection(kind)
    setDraft(c)
    setPassword('')
    setSelectedId(null)
    setTestResult(null)
  }

  const isNew = !connections.find(c => c.id === draft.id)

  function saveAndReturn(): ConnectionConfig {
    const c = { ...draft }
    if (!c.name.trim()) c.name = connectionDisplayName(c)
    setDraft(c)
    const updated = isNew ? [...connections, c] : connections.map(x => x.id === c.id ? c : x)
    setConnections(updated)
    api.saveConnection(c, password)
    setSelectedId(c.id)
    return c
  }

  async function handleTest() {
    const c = saveAndReturn()
    setBusy('Testing…')
    setTestResult(null)
    const r = await api.testConnection(c, password)
    setTestResult(r)
    setBusy('')
  }

  async function handleConnect() {
    const c = saveAndReturn()
    setBusy('Connecting…')
    setTestResult(null)
    try {
      const sessionId = await api.connect(c, password)
      const ver = await api.serverVersion(sessionId)
      setBusy('')
      onConnect({ sessionId, config: c, password, serverVersion: ver })
    } catch (e: unknown) {
      setTestResult({ ok: false, message: e instanceof Error ? e.message : String(e) })
      setBusy('')
    }
  }

  async function handleDelete(id: string) {
    if (!confirm('Delete this connection? The database itself is not affected.')) return
    await api.deleteConnection(id)
    const updated = connections.filter(c => c.id !== id)
    setConnections(updated)
    if (updated.length > 0) selectConnection(updated[0].id, updated)
    else newConnection()
  }

  const grouped = (() => {
    const f = filter.toLowerCase()
    const filtered = f ? connections.filter(c =>
      connectionDisplayName(c).toLowerCase().includes(f) ||
      connectionSummary(c).toLowerCase().includes(f) ||
      c.group.toLowerCase().includes(f)
    ) : connections
    const map: Record<string, ConnectionConfig[]> = {}
    for (const c of filtered) {
      const g = c.group || ''
      ;(map[g] ??= []).push(c)
    }
    return Object.entries(map).sort(([a], [b]) => (!a ? -1 : !b ? 1 : a.localeCompare(b)))
  })()

  function patch<K extends keyof ConnectionConfig>(key: K, value: ConnectionConfig[K]) {
    setDraft(d => ({ ...d, [key]: value }))
    setTestResult(null)
  }

  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <div className="flex flex-col w-[280px] shrink-0" style={{ background: '#161618', borderRight: '1px solid rgba(255,255,255,0.08)' }}>
        <div className="flex items-center px-4 h-[52px]" style={{ borderBottom: '1px solid rgba(255,255,255,0.08)' }}>
          <span className="font-semibold text-mb-text tracking-tight text-[15px]">Maben Base</span>
        </div>
        <div className="p-2.5">
          <input
            className="mb-field"
            placeholder="Search connections"
            value={filter}
            onChange={e => setFilter(e.target.value)}
          />
        </div>
        <div className="flex-1 overflow-y-auto py-1">
          {grouped.map(([group, items]) => (
            <div key={group}>
              {group && (
                <div className="px-4 py-2 text-[10.5px] font-semibold tracking-wider text-mb-dim uppercase">
                  {group}
                </div>
              )}
              {items.map(c => (
                <ConnectionRow
                  key={c.id}
                  config={c}
                  selected={selectedId === c.id}
                  onClick={() => selectConnection(c.id)}
                  onDoubleClick={() => { selectConnection(c.id); handleConnect() }}
                  onDelete={() => handleDelete(c.id)}
                />
              ))}
            </div>
          ))}
          {connections.length === 0 && (
            <div className="px-4 py-4 text-mb-dim text-xs">No connections yet</div>
          )}
        </div>
        <div style={{ borderTop: '1px solid rgba(255,255,255,0.08)' }} className="px-3.5 h-[44px] flex items-center gap-1">
          <button className="mb-btn text-xs py-1 px-2.5" onClick={() => newConnection()}>+ New</button>
          <div className="relative group">
            <button className="mb-btn text-xs py-1 px-2" title="New connection with type…">▾</button>
            <div className="absolute bottom-full left-0 mb-1 hidden group-hover:block z-50 rounded-lg overflow-hidden shadow-2xl"
              style={{ background: '#252527', border: '1px solid rgba(255,255,255,0.1)', minWidth: 180 }}>
              {ALL_KINDS.map(k => (
                <button key={k} className="block w-full text-left px-3 py-1.5 text-xs text-mb-text hover:bg-[rgba(255,255,255,0.07)]"
                  onClick={() => newConnection(k)}>
                  {kindTitle(k)}
                  {!SUPPORTED_KINDS.includes(k) && <span className="text-mb-dim ml-1 text-[10px]">(coming soon)</span>}
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Editor */}
      <div className="flex flex-col flex-1 overflow-hidden" style={{ background: '#1c1c1e' }}>
        <div className="flex items-center px-6 h-[52px]" style={{ borderBottom: '1px solid rgba(255,255,255,0.08)' }}>
          <span className="font-semibold text-mb-text text-[15px] truncate">
            {isNew ? 'New connection' : connectionDisplayName(draft)}
          </span>
        </div>

        <div className="flex-1 overflow-y-auto">
          <div className="px-6 py-5 max-w-[600px] space-y-4">
            <Row label="Type">
              <select className="mb-field" value={draft.kind} onChange={e => {
                const k = e.target.value as DatabaseKind
                patch('kind', k)
                if (draft.port === defaultPort(draft.kind) || draft.port === 0) patch('port', defaultPort(k))
                patch('tls', isFileKind(k) ? 'off' : 'prefer')
              }}>
                {ALL_KINDS.map(k => (
                  <option key={k} value={k}>{kindTitle(k)}{!SUPPORTED_KINDS.includes(k) ? ' (coming soon)' : ''}</option>
                ))}
              </select>
            </Row>

            <Row label="Name">
              <input className="mb-field" placeholder={connectionDisplayName(draft)} value={draft.name}
                onChange={e => patch('name', e.target.value)} />
            </Row>

            <Row label="Tag">
              <div className="flex gap-1.5">
                {(['local', 'development', 'staging', 'production'] as Environment[]).map(env => (
                  <button key={env} onClick={() => patch('environment', env)}
                    className="px-2.5 py-1 rounded-md text-xs font-medium transition-all"
                    style={{
                      background: draft.environment === env ? envColor(env) + '33' : 'rgba(255,255,255,0.05)',
                      border: `1px solid ${draft.environment === env ? envColor(env) : 'rgba(255,255,255,0.1)'}`,
                      color: draft.environment === env ? envColor(env) : '#888',
                    }}>
                    {env.charAt(0).toUpperCase() + env.slice(1)}
                  </button>
                ))}
              </div>
            </Row>

            <Row label="Group">
              <input className="mb-field" placeholder="Optional, e.g. a client or project" value={draft.group}
                onChange={e => patch('group', e.target.value)} />
            </Row>

            <div className="hairline hairline-h" />

            {isFileKind(draft.kind) ? (
              <Row label="File">
                <input className="mb-field mono" placeholder="C:\path\to\database.sqlite, or empty for in-memory"
                  value={draft.filePath} onChange={e => patch('filePath', e.target.value)} />
              </Row>
            ) : isCloudKind(draft.kind) ? (
              <CloudFields draft={draft} patch={patch} password={password} setPassword={setPassword} />
            ) : (
              <>
                <Row label={draft.kind === 'libsql' ? 'URL' : 'Host'}>
                  <div className="flex items-center gap-2">
                    <input className="mb-field mono flex-1" placeholder="127.0.0.1"
                      value={draft.host} onChange={e => patch('host', e.target.value)} />
                    {draft.kind !== 'libsql' && (
                      <>
                        <span className="text-mb-dim text-xs shrink-0">Port</span>
                        <input className="mb-field mono" style={{ width: 72 }}
                          placeholder={String(defaultPort(draft.kind))} value={draft.port || ''}
                          onChange={e => patch('port', parseInt(e.target.value.replace(/\D/g, '')) || 0)} />
                      </>
                    )}
                  </div>
                </Row>

                {draft.kind !== 'libsql' && (
                  <Row label="User">
                    <input className="mb-field mono" placeholder="user" value={draft.user}
                      onChange={e => patch('user', e.target.value)} />
                  </Row>
                )}

                <Row label={draft.kind === 'libsql' ? 'Token' : 'Password'}>
                  <input className="mb-field" type="password"
                    placeholder={draft.kind === 'libsql' ? 'Auth token' : 'Password'}
                    value={password} onChange={e => setPassword(e.target.value)} />
                </Row>

                <Row label={draft.kind === 'redis' ? 'DB number' : draft.kind === 'cassandra' ? 'Keyspace' : 'Database'}>
                  <input className="mb-field mono"
                    placeholder={draft.kind === 'postgres' ? 'Defaults to user name' : draft.kind === 'sqlserver' ? 'master' : 'Optional'}
                    value={draft.database} onChange={e => patch('database', e.target.value)} />
                </Row>

                <Row label="TLS">
                  <div className="flex items-center gap-3">
                    <div className="flex gap-1">
                      {(['off', 'prefer', 'require', 'verify'] as TLS[]).map(t => (
                        <button key={t} onClick={() => patch('tls', t)}
                          className="px-2.5 py-1 rounded-md text-xs font-medium transition-all"
                          style={{
                            background: draft.tls === t ? 'rgba(59,130,246,0.2)' : 'rgba(255,255,255,0.05)',
                            border: `1px solid ${draft.tls === t ? 'rgba(59,130,246,0.5)' : 'rgba(255,255,255,0.1)'}`,
                            color: draft.tls === t ? '#93c5fd' : '#888',
                          }}>
                          {tlsTitle(t)}
                        </button>
                      ))}
                    </div>
                  </div>
                </Row>

                <Row label="SSH">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input type="checkbox" checked={draft.sshEnabled} onChange={e => patch('sshEnabled', e.target.checked)} />
                    <span className="text-mb-text text-[12.5px]">Connect through an SSH tunnel</span>
                  </label>
                </Row>

                {draft.sshEnabled && (
                  <>
                    <Row label="SSH host">
                      <div className="flex items-center gap-2">
                        <input className="mb-field mono flex-1" placeholder="server or ~/.ssh/config alias"
                          value={draft.sshHost} onChange={e => patch('sshHost', e.target.value)} />
                        <span className="text-mb-dim text-xs shrink-0">Port</span>
                        <input className="mb-field mono" style={{ width: 64 }} placeholder="22"
                          value={draft.sshPort} onChange={e => patch('sshPort', parseInt(e.target.value) || 22)} />
                      </div>
                    </Row>
                    <Row label="SSH user">
                      <input className="mb-field mono" placeholder="Optional, from ~/.ssh/config"
                        value={draft.sshUser} onChange={e => patch('sshUser', e.target.value)} />
                    </Row>
                    <Row label="Key file">
                      <input className="mb-field mono" placeholder="Optional; your ssh agent is used otherwise"
                        value={draft.sshKeyPath} onChange={e => patch('sshKeyPath', e.target.value)} />
                    </Row>
                  </>
                )}
              </>
            )}

            <div className="hairline hairline-h" />

            <Row label="Safe mode">
              <select className="mb-field" value={draft.safeMode} onChange={e => patch('safeMode', e.target.value as SafeMode)}>
                <option value="off">Off — queries and edits run right away</option>
                <option value="confirmWrites">Ask before writes</option>
                <option value="confirmAll">Ask before every query</option>
                <option value="readOnly">Read-only — editing is off</option>
              </select>
            </Row>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center gap-3 px-5 h-[54px]" style={{ borderTop: '1px solid rgba(255,255,255,0.08)', background: '#141416' }}>
          {busy ? (
            <div className="flex items-center gap-2 text-xs text-mb-muted">
              <span className="animate-spin text-mb-accent">⟳</span>
              {busy}
            </div>
          ) : testResult ? (
            <div className="flex items-center gap-2 text-xs flex-1 min-w-0">
              <span style={{ color: testResult.ok ? '#22c55e' : '#ef4444' }}>
                {testResult.ok ? '✓' : '✕'}
              </span>
              <span className="truncate" style={{ color: testResult.ok ? '#888' : '#ef4444' }}>
                {testResult.message}
              </span>
            </div>
          ) : <div className="flex-1" />}
          <div className="flex items-center gap-2 ml-auto">
            <button className="mb-btn text-xs" onClick={handleTest} disabled={!!busy}>Test</button>
            <button className="mb-btn text-xs" onClick={() => saveAndReturn()} disabled={!!busy}>Save</button>
            <button className="mb-btn-primary text-xs" onClick={handleConnect} disabled={!!busy}>Connect</button>
          </div>
        </div>
      </div>
    </div>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start gap-4">
      <div className="text-mb-muted text-[12.5px] text-right pt-1.5 shrink-0" style={{ width: 80 }}>{label}</div>
      <div className="flex-1 min-w-0">{children}</div>
    </div>
  )
}

function CloudFields({ draft, patch, password, setPassword }: {
  draft: ConnectionConfig
  patch: <K extends keyof ConnectionConfig>(k: K, v: ConnectionConfig[K]) => void
  password: string
  setPassword: (p: string) => void
}) {
  if (draft.kind === 'd1') return (
    <>
      <Row label="Account ID">
        <input className="mb-field mono" placeholder="Cloudflare account ID" value={draft.host} onChange={e => patch('host', e.target.value)} />
      </Row>
      <Row label="Database ID">
        <input className="mb-field mono" placeholder="The D1 database's UUID" value={draft.database} onChange={e => patch('database', e.target.value)} />
      </Row>
      <Row label="API token">
        <input className="mb-field" type="password" placeholder="A token with D1 edit permission" value={password} onChange={e => setPassword(e.target.value)} />
      </Row>
    </>
  )
  return <Row label=""><span className="text-mb-dim text-xs">{kindTitle(draft.kind)} support coming soon.</span></Row>
}

function ConnectionRow({ config, selected, onClick, onDoubleClick, onDelete }: {
  config: ConnectionConfig
  selected: boolean
  onClick: () => void
  onDoubleClick: () => void
  onDelete: () => void
}) {
  const [hover, setHover] = useState(false)

  return (
    <div
      className="flex items-center gap-2.5 px-3 py-1.5 mx-1.5 rounded-lg cursor-pointer transition-colors"
      style={{ background: selected ? 'rgba(59,130,246,0.14)' : hover ? 'rgba(255,255,255,0.05)' : 'transparent' }}
      onClick={onClick}
      onDoubleClick={onDoubleClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      onContextMenu={e => { e.preventDefault(); onDelete() }}
    >
      <div className="relative shrink-0">
        <div className="w-7 h-7 rounded-[7px] flex items-center justify-center text-mb-muted text-[11px] font-bold"
          style={{ background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.08)' }}>
          {kindShortIcon(config.kind)}
        </div>
        <div className="absolute -bottom-0.5 -right-0.5 w-2 h-2 rounded-full"
          style={{ background: envColor(config.environment), boxShadow: `0 0 0 1.5px #161618` }} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-mb-text text-[13px] font-medium truncate leading-tight">
          {connectionDisplayName(config)}
        </div>
        <div className="text-mb-dim text-[11px] truncate leading-tight">
          {connectionSummary(config)}
        </div>
      </div>
    </div>
  )
}

function kindShortIcon(kind: DatabaseKind): string {
  const icons: Record<DatabaseKind, string> = {
    postgres: 'PG', mysql: 'MY', sqlite: 'LT', sqlserver: 'MS', oracle: 'OR',
    clickhouse: 'CH', duckdb: 'DK', libsql: 'LS', d1: 'D1', snowflake: 'SF',
    bigquery: 'BQ', cassandra: 'CS', mongodb: 'MG', redis: 'RD',
  }
  return icons[kind]
}
