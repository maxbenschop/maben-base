import { useState, useEffect } from 'react'
import { ActiveSession, DBObject } from './types'

interface Props {
  session: ActiveSession
  onOpenTable: (obj: DBObject) => void
  onDbChange: (db: string) => void
}

export default function ObjectBrowser({ session, onOpenTable, onDbChange }: Props) {
  const [databases, setDatabases] = useState<string[]>([])
  const [currentDb, setCurrentDb] = useState(session.config.database || '')
  const [schemas, setSchemas] = useState<string[]>([])
  const [objects, setObjects] = useState<DBObject[]>([])
  const [expandedSchema, setExpandedSchema] = useState<string | null>('public')
  const [filter, setFilter] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const api = (window as unknown as { api: { databases: (s: string) => Promise<string[]>; useDatabase: (s: string, d: string, c: unknown, p: string) => Promise<void>; schemas: (s: string) => Promise<string[]>; objects: (s: string, schema?: string) => Promise<DBObject[]> } }).api

  async function loadObjects(schema?: string) {
    try {
      const objs = await api.objects(session.sessionId, schema)
      setObjects(objs)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  async function loadSchemas() {
    try {
      const sch = await api.schemas(session.sessionId)
      setSchemas(sch)
      const def = sch[0] || null
      setExpandedSchema(def)
      if (def) await loadObjects(def)
    } catch {
      await loadObjects()
    }
  }

  useEffect(() => {
    setLoading(true)
    setError('')
    Promise.all([
      api.databases(session.sessionId),
      loadSchemas(),
    ]).then(([dbs]) => {
      setDatabases(dbs)
      if (!currentDb && dbs[0]) setCurrentDb(dbs[0])
    }).catch(e => setError(e.message)).finally(() => setLoading(false))
  }, [session.sessionId])

  async function switchDatabase(db: string) {
    setCurrentDb(db)
    onDbChange(db)
    setLoading(true)
    try {
      await api.useDatabase(session.sessionId, db, session.config, session.password)
      await loadSchemas()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  async function toggleSchema(schema: string) {
    if (expandedSchema === schema) {
      setExpandedSchema(null)
    } else {
      setExpandedSchema(schema)
      await loadObjects(schema)
    }
  }

  const filteredObjects = filter
    ? objects.filter(o => o.name.toLowerCase().includes(filter.toLowerCase()))
    : objects

  const tables = filteredObjects.filter(o => o.kind === 'table')
  const views = filteredObjects.filter(o => o.kind === 'view')

  if (loading) {
    return (
      <div className="flex flex-col h-full">
        <div className="p-2.5 border-b" style={{ borderColor: 'rgba(255,255,255,0.08)' }}>
          <div className="mb-field text-mb-dim text-xs">Loading…</div>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col h-full text-[12.5px]">
      {/* Database picker */}
      {databases.length > 1 && (
        <div className="p-2 border-b" style={{ borderColor: 'rgba(255,255,255,0.08)' }}>
          <select className="mb-field text-xs py-1" value={currentDb} onChange={e => switchDatabase(e.target.value)}>
            {databases.map(db => <option key={db}>{db}</option>)}
          </select>
        </div>
      )}

      {/* Filter */}
      <div className="p-2 border-b" style={{ borderColor: 'rgba(255,255,255,0.08)' }}>
        <input className="mb-field text-xs py-1" placeholder="Filter tables…" value={filter} onChange={e => setFilter(e.target.value)} />
      </div>

      {error && <div className="px-3 py-2 text-mb-red text-xs">{error}</div>}

      <div className="flex-1 overflow-y-auto py-1">
        {schemas.length > 1 ? (
          schemas.map(schema => (
            <div key={schema}>
              <button
                className="flex items-center gap-1.5 w-full px-3 py-1 text-mb-muted hover:text-mb-text hover:bg-[rgba(255,255,255,0.05)] text-left"
                onClick={() => toggleSchema(schema)}>
                <span className="text-[9px]">{expandedSchema === schema ? '▼' : '▶'}</span>
                <span className="font-medium">{schema}</span>
              </button>
              {expandedSchema === schema && (
                <ObjectList tables={tables} views={views} onOpen={onOpenTable} indent />
              )}
            </div>
          ))
        ) : (
          <ObjectList tables={tables} views={views} onOpen={onOpenTable} />
        )}

        {!loading && tables.length === 0 && views.length === 0 && !error && (
          <div className="px-3 py-3 text-mb-dim text-xs">No tables found</div>
        )}
      </div>
    </div>
  )
}

function ObjectList({ tables, views, onOpen, indent }: {
  tables: DBObject[]
  views: DBObject[]
  onOpen: (obj: DBObject) => void
  indent?: boolean
}) {
  const [hoverId, setHoverId] = useState<string | null>(null)
  const pl = indent ? 'pl-6' : 'pl-3'

  return (
    <>
      {tables.length > 0 && (
        <>
          {views.length > 0 && (
            <div className={`${pl} pr-3 py-0.5 text-[10px] font-semibold tracking-wider uppercase text-mb-dim`}>
              Tables
            </div>
          )}
          {tables.map(obj => (
            <ObjectRow key={obj.name} obj={obj} onOpen={onOpen} pl={pl} hoverId={hoverId} setHoverId={setHoverId} icon="⊞" />
          ))}
        </>
      )}
      {views.length > 0 && (
        <>
          <div className={`${pl} pr-3 py-0.5 text-[10px] font-semibold tracking-wider uppercase text-mb-dim mt-1`}>
            Views
          </div>
          {views.map(obj => (
            <ObjectRow key={obj.name} obj={obj} onOpen={onOpen} pl={pl} hoverId={hoverId} setHoverId={setHoverId} icon="⊚" />
          ))}
        </>
      )}
    </>
  )
}

function ObjectRow({ obj, onOpen, pl, hoverId, setHoverId, icon }: {
  obj: DBObject
  onOpen: (obj: DBObject) => void
  pl: string
  hoverId: string | null
  setHoverId: (id: string | null) => void
  icon: string
}) {
  const id = `${obj.schema ?? ''}-${obj.name}`
  const hover = hoverId === id
  return (
    <button
      className={`flex items-center gap-1.5 w-full ${pl} pr-3 py-1 text-left truncate transition-colors`}
      style={{
        background: hover ? 'rgba(255,255,255,0.05)' : 'transparent',
        color: hover ? '#efefef' : '#aaa',
      }}
      onMouseEnter={() => setHoverId(id)}
      onMouseLeave={() => setHoverId(null)}
      onDoubleClick={() => onOpen(obj)}
      onClick={() => onOpen(obj)}>
      <span className="text-[10px] text-mb-dim">{icon}</span>
      <span className="truncate">{obj.name}</span>
    </button>
  )
}
