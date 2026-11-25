import { useState, useEffect, useRef, useCallback } from 'react'
import { ActiveSession, DBObject, ColumnInfo, PageResult } from './types'

interface Edit { rowIdx: number; col: string; oldValue: string | null; newValue: string | null }

interface Props {
  session: ActiveSession
  table: DBObject
}

const PAGE_SIZE = 100

export default function DataGrid({ session, table }: Props) {
  const api = (window as unknown as { api: { fetchPage: (s: string, t: string, sch: string | null, p: number, ps: number, sort?: unknown) => Promise<PageResult>; columns: (s: string, t: string, sch?: string) => Promise<ColumnInfo[]>; saveEdits: (s: string, t: string, sch: string | null, edits: unknown[]) => Promise<void> } }).api

  const [page, setPage] = useState(0)
  const [result, setResult] = useState<PageResult | null>(null)
  const [columns, setColumns] = useState<ColumnInfo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [edits, setEdits] = useState<Map<string, Edit>>(new Map())
  const [editCell, setEditCell] = useState<{ row: number; col: string } | null>(null)
  const [editValue, setEditValue] = useState('')
  const [sort, setSort] = useState<{ col: string; dir: 'asc' | 'desc' } | null>(null)
  const [saving, setSaving] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  async function load(p = page, s = sort) {
    setLoading(true)
    setError('')
    try {
      const r = await api.fetchPage(session.sessionId, table.name, table.schema ?? null, p, PAGE_SIZE, s ?? undefined)
      setResult(r)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    api.columns(session.sessionId, table.name, table.schema).then(setColumns).catch(() => {})
    load(0, null)
  }, [table.name, table.schema])

  function handleSort(col: string) {
    const next = sort?.col === col ? (sort.dir === 'asc' ? { col, dir: 'desc' as const } : null) : { col, dir: 'asc' as const }
    setSort(next)
    setPage(0)
    load(0, next)
  }

  function startEdit(rowIdx: number, col: string, currentVal: string | null) {
    if (session.config.safeMode === 'readOnly') return
    setEditCell({ row: rowIdx, col })
    setEditValue(currentVal ?? '')
    setTimeout(() => inputRef.current?.select(), 10)
  }

  function commitEdit(rowIdx: number, col: string) {
    if (!result) return
    const colIdx = result.columns.findIndex(c => c.name === col)
    const oldValue = result.rows[rowIdx][colIdx]
    const newValue = editValue
    if (newValue === oldValue) { setEditCell(null); return }
    const pk = columns.find(c => c.isPrimaryKey)
    if (!pk) { setEditCell(null); return }
    const pkColIdx = result.columns.findIndex(c => c.name === pk.name)
    const pkValue = result.rows[rowIdx][pkColIdx] ?? ''
    const key = `${rowIdx}-${col}`
    setEdits(m => { const n = new Map(m); n.set(key, { rowIdx, col, oldValue, newValue }); return n })
    setResult(r => r ? {
      ...r,
      rows: r.rows.map((row, i) => i === rowIdx ? row.map((v, j) => r.columns[j].name === col ? newValue : v) : row)
    } : r)
    setEditCell(null)
  }

  async function saveAll() {
    if (edits.size === 0) return
    const pk = columns.find(c => c.isPrimaryKey)
    if (!pk || !result) return
    setSaving(true)
    setError('')
    try {
      const pkColIdx = result.columns.findIndex(c => c.name === pk.name)
      const editList = Array.from(edits.values()).map(e => ({
        pkColumn: pk.name,
        pkValue: result.rows[e.rowIdx][pkColIdx] ?? '',
        column: e.col,
        newValue: e.newValue,
      }))
      await api.saveEdits(session.sessionId, table.name, table.schema ?? null, editList)
      setEdits(new Map())
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  function discardEdits() {
    setEdits(new Map())
    load()
  }

  const totalPages = result ? Math.ceil(result.total / PAGE_SIZE) : 0
  const hasPk = columns.some(c => c.isPrimaryKey)
  const hasEdits = edits.size > 0

  return (
    <div className="flex flex-col h-full" style={{ background: '#1c1c1e' }}>
      {/* Toolbar */}
      <div className="flex items-center gap-3 px-4 h-9 shrink-0" style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', background: '#141416' }}>
        <span className="text-mb-muted text-xs font-mono">{table.schema ? `${table.schema}.` : ''}{table.name}</span>
        {result && <span className="text-mb-dim text-xs">{result.total.toLocaleString()} rows</span>}
        <div className="flex-1" />
        {hasEdits && (
          <>
            <span className="text-mb-orange text-xs">{edits.size} unsaved change{edits.size !== 1 ? 's' : ''}</span>
            <button className="mb-btn text-xs py-0.5 px-2" onClick={discardEdits}>Discard</button>
            <button className="mb-btn-primary text-xs py-0.5 px-2" onClick={saveAll} disabled={saving}>
              {saving ? 'Saving…' : 'Save'}
            </button>
          </>
        )}
        <button className="mb-btn text-xs py-0.5 px-2" onClick={() => load()} title="Refresh">↻</button>
      </div>

      {error && <div className="px-4 py-2 text-mb-red text-xs border-b" style={{ borderColor: 'rgba(255,255,255,0.08)' }}>{error}</div>}

      {/* Table */}
      <div className="flex-1 overflow-auto relative">
        {loading && (
          <div className="absolute inset-0 flex items-center justify-center bg-[rgba(28,28,30,0.7)] z-10">
            <span className="text-mb-dim text-xs">Loading…</span>
          </div>
        )}
        {result && (
          <table className="w-full text-xs border-collapse select-text">
            <thead className="sticky top-0 z-10" style={{ background: '#161618' }}>
              <tr>
                <th className="w-10 px-2 py-1.5 text-right text-mb-dim font-normal" style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', borderRight: '1px solid rgba(255,255,255,0.08)' }}>#</th>
                {result.columns.map(col => {
                  const info = columns.find(c => c.name === col.name)
                  const isSorted = sort?.col === col.name
                  return (
                    <th key={col.name}
                      className="text-left px-2.5 py-1.5 cursor-pointer hover:bg-[rgba(255,255,255,0.04)] whitespace-nowrap"
                      style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', borderRight: '1px solid rgba(255,255,255,0.05)', userSelect: 'none' }}
                      onClick={() => handleSort(col.name)}>
                      <div className="flex items-center gap-1">
                        {info?.isPrimaryKey && <span className="text-mb-accent text-[9px]">PK</span>}
                        <span className="text-mb-text font-medium">{col.name}</span>
                        <span className="text-mb-dim font-normal text-[10px]">{col.typeName || info?.type}</span>
                        {isSorted && <span className="text-mb-accent text-[9px]">{sort.dir === 'asc' ? '↑' : '↓'}</span>}
                      </div>
                    </th>
                  )
                })}
              </tr>
            </thead>
            <tbody>
              {result.rows.map((row, rowIdx) => (
                <tr key={rowIdx} className="group" style={{ borderBottom: '1px solid rgba(255,255,255,0.04)' }}>
                  <td className="px-2 py-0.5 text-right text-mb-dim tabular-nums" style={{ borderRight: '1px solid rgba(255,255,255,0.08)', background: '#161618' }}>
                    {page * PAGE_SIZE + rowIdx + 1}
                  </td>
                  {row.map((val, colIdx) => {
                    const colName = result.columns[colIdx].name
                    const isEditing = editCell?.row === rowIdx && editCell?.col === colName
                    const editKey = `${rowIdx}-${colName}`
                    const isEdited = edits.has(editKey)
                    return (
                      <td key={colIdx}
                        className="px-2.5 py-0.5 max-w-[280px] overflow-hidden"
                        style={{
                          borderRight: '1px solid rgba(255,255,255,0.04)',
                          background: isEdited ? 'rgba(59,130,246,0.08)' : undefined,
                        }}
                        onDoubleClick={() => startEdit(rowIdx, colName, val)}>
                        {isEditing ? (
                          <input
                            ref={inputRef}
                            className="w-full bg-[rgba(59,130,246,0.15)] outline outline-1 outline-[rgba(59,130,246,0.6)] rounded px-1 font-mono text-xs text-mb-text"
                            value={editValue}
                            onChange={e => setEditValue(e.target.value)}
                            onBlur={() => commitEdit(rowIdx, colName)}
                            onKeyDown={e => {
                              if (e.key === 'Enter') commitEdit(rowIdx, colName)
                              if (e.key === 'Escape') setEditCell(null)
                            }}
                          />
                        ) : (
                          <span className={`font-mono whitespace-nowrap ${val === null ? 'text-mb-dim italic' : 'text-mb-text'}`}>
                            {val === null ? 'NULL' : val.length > 100 ? val.slice(0, 100) + '…' : val}
                          </span>
                        )}
                      </td>
                    )
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Pagination */}
      {result && totalPages > 1 && (
        <div className="flex items-center justify-between px-4 h-9 shrink-0" style={{ borderTop: '1px solid rgba(255,255,255,0.08)', background: '#141416' }}>
          <div className="flex items-center gap-2">
            <button className="mb-btn text-xs py-0.5 px-2" disabled={page === 0} onClick={() => { setPage(0); load(0) }}>⟨⟨</button>
            <button className="mb-btn text-xs py-0.5 px-2" disabled={page === 0} onClick={() => { const p = page - 1; setPage(p); load(p) }}>⟨</button>
          </div>
          <span className="text-mb-dim text-xs">Page {page + 1} of {totalPages} · {result.total.toLocaleString()} rows</span>
          <div className="flex items-center gap-2">
            <button className="mb-btn text-xs py-0.5 px-2" disabled={page >= totalPages - 1} onClick={() => { const p = page + 1; setPage(p); load(p) }}>⟩</button>
            <button className="mb-btn text-xs py-0.5 px-2" disabled={page >= totalPages - 1} onClick={() => { const p = totalPages - 1; setPage(p); load(p) }}>⟩⟩</button>
          </div>
        </div>
      )}

      {!hasPk && result && result.total > 0 && (
        <div className="px-4 py-1.5 text-mb-dim text-xs" style={{ borderTop: '1px solid rgba(255,255,255,0.08)', background: '#141416' }}>
          No primary key — editing is disabled for this table
        </div>
      )}
    </div>
  )
}
