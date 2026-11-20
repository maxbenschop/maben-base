import { useState, useCallback, useRef } from 'react'
import CodeMirror from '@uiw/react-codemirror'
import { sql } from '@codemirror/lang-sql'
import { oneDark } from '@codemirror/theme-one-dark'
import { EditorView, keymap } from '@codemirror/view'
import { Prec } from '@codemirror/state'
import { ActiveSession, QueryResult } from './types'

interface Props {
  session: ActiveSession
  currentDb: string
}

const editorTheme = EditorView.theme({
  '&': { background: '#1c1c1e', fontSize: '12.5px', height: '100%' },
  '.cm-content': { fontFamily: '"Cascadia Code", Consolas, monospace', caretColor: '#3b82f6', padding: '12px 0' },
  '.cm-gutters': { background: '#161618', borderRight: '1px solid rgba(255,255,255,0.08)', color: '#555' },
  '.cm-lineNumbers .cm-gutterElement': { paddingRight: '10px', paddingLeft: '8px' },
  '.cm-selectionBackground': { background: 'rgba(59,130,246,0.25) !important' },
  '.cm-cursor': { borderLeftColor: '#3b82f6' },
  '.cm-activeLine': { background: 'rgba(255,255,255,0.025)' },
  '.cm-activeLineGutter': { background: 'rgba(255,255,255,0.03)' },
  '&.cm-focused': { outline: 'none' },
})

export default function SQLEditor({ session, currentDb }: Props) {
  const api = (window as unknown as { api: { execute: (s: string, sql: string, limit?: number) => Promise<QueryResult[]> } }).api
  const [code, setCode] = useState('-- Write your SQL here\n-- Press Ctrl+Enter or Cmd+Enter to run\n\n')
  const [results, setResults] = useState<QueryResult[] | null>(null)
  const [error, setError] = useState('')
  const [running, setRunning] = useState(false)
  const [elapsed, setElapsed] = useState<number | null>(null)
  const editorViewRef = useRef<EditorView | null>(null)

  async function runQuery(queryOverride?: string) {
    const q = queryOverride ?? getSelectedOrAll()
    if (!q.trim()) return
    setRunning(true)
    setError('')
    setResults(null)
    const start = Date.now()
    try {
      const r = await api.execute(session.sessionId, q, 1000)
      setResults(r)
      setElapsed(Date.now() - start)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e))
      setElapsed(Date.now() - start)
    } finally {
      setRunning(false)
    }
  }

  function getSelectedOrAll(): string {
    const view = editorViewRef.current
    if (view) {
      const sel = view.state.selection.main
      if (!sel.empty) return view.state.sliceDoc(sel.from, sel.to)
    }
    return code
  }

  const runKeymap = Prec.highest(keymap.of([{
    key: 'Ctrl-Enter',
    mac: 'Cmd-Enter',
    run: () => { runQuery(); return true },
  }]))

  const totalRows = results?.reduce((s, r) => s + r.rows.length, 0) ?? 0
  const affectedRows = results?.find(r => r.affectedRows != null)?.affectedRows

  return (
    <div className="flex flex-col h-full">
      {/* Editor area */}
      <div className="relative flex-[0_0_55%] min-h-[120px] border-b" style={{ borderColor: 'rgba(255,255,255,0.08)' }}>
        <CodeMirror
          value={code}
          onChange={setCode}
          extensions={[sql(), editorTheme, runKeymap]}
          theme={oneDark}
          style={{ height: '100%' }}
          onCreateEditor={view => { editorViewRef.current = view }}
        />
        <div className="absolute bottom-2.5 right-3 flex items-center gap-2">
          {running && <span className="text-mb-dim text-xs animate-pulse">Running…</span>}
          <button
            className="mb-btn-primary text-xs py-1 px-3"
            onClick={() => runQuery()}
            disabled={running}>
            Run ⌃⏎
          </button>
        </div>
      </div>

      {/* Results area */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {/* Result tabs */}
        <div className="flex items-center gap-4 px-4 h-8 shrink-0" style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', background: '#141416' }}>
          {results && (
            <>
              <span className="text-mb-muted text-xs font-medium">Results</span>
              {totalRows > 0 && <span className="text-mb-dim text-xs">{totalRows.toLocaleString()} row{totalRows !== 1 ? 's' : ''}</span>}
              {affectedRows != null && <span className="text-mb-dim text-xs">{affectedRows} row{affectedRows !== 1 ? 's' : ''} affected</span>}
              {results[0]?.message && <span className="text-mb-dim text-xs">{results[0].message}</span>}
            </>
          )}
          {error && <span className="text-mb-red text-xs font-medium">Error</span>}
          {elapsed != null && <span className="text-mb-dim text-xs ml-auto">{elapsed}ms</span>}
        </div>

        <div className="flex-1 overflow-auto">
          {error && (
            <div className="px-4 py-3">
              <pre className="text-mb-red text-xs font-mono whitespace-pre-wrap">{error}</pre>
            </div>
          )}

          {results && results.map((result, ri) => (
            <div key={ri}>
              {results.length > 1 && (
                <div className="px-4 py-1 text-mb-dim text-[10px] border-b" style={{ borderColor: 'rgba(255,255,255,0.06)', background: '#161618' }}>
                  Statement {ri + 1}
                </div>
              )}
              {result.columns.length > 0 ? (
                <table className="w-full text-xs border-collapse select-text">
                  <thead className="sticky top-0 z-10" style={{ background: '#161618' }}>
                    <tr>
                      {result.columns.map(col => (
                        <th key={col.name} className="text-left px-2.5 py-1.5 text-mb-muted font-medium whitespace-nowrap"
                          style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', borderRight: '1px solid rgba(255,255,255,0.05)' }}>
                          <span>{col.name}</span>
                          {col.typeName && <span className="text-mb-dim font-normal text-[10px] ml-1">{col.typeName}</span>}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {result.rows.map((row, ri) => (
                      <tr key={ri} style={{ borderBottom: '1px solid rgba(255,255,255,0.04)' }}
                        className="hover:bg-[rgba(255,255,255,0.025)]">
                        {row.map((val, ci) => (
                          <td key={ci} className="px-2.5 py-0.5 max-w-[320px] overflow-hidden"
                            style={{ borderRight: '1px solid rgba(255,255,255,0.04)' }}>
                            <span className={`font-mono whitespace-nowrap ${val === null ? 'text-mb-dim italic' : 'text-mb-text'}`}>
                              {val === null ? 'NULL' : val.length > 150 ? val.slice(0, 150) + '…' : val}
                            </span>
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : (
                <div className="px-4 py-3 text-mb-muted text-xs">
                  {result.affectedRows != null ? `${result.affectedRows} row${result.affectedRows !== 1 ? 's' : ''} affected` : result.message ?? 'OK'}
                </div>
              )}
              {result.truncated && (
                <div className="px-4 py-1.5 text-mb-orange text-xs border-t" style={{ borderColor: 'rgba(255,255,255,0.06)' }}>
                  Results truncated to 1,000 rows
                </div>
              )}
            </div>
          ))}

          {!results && !error && !running && (
            <div className="flex items-center justify-center h-full text-mb-dim text-xs">
              Press Ctrl+Enter to run
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
