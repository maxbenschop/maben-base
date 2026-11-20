import { useState } from 'react'
import { ActiveSession, DBObject, connectionDisplayName, envColor } from './types'
import ObjectBrowser from './ObjectBrowser'
import DataGrid from './DataGrid'
import SQLEditor from './SQLEditor'

interface Tab {
  id: string
  label: string
  kind: 'table' | 'query'
  table?: DBObject
}

interface Props {
  session: ActiveSession
  onDisconnect: () => void
}

export default function WorkspaceView({ session, onDisconnect }: Props) {
  const [tabs, setTabs] = useState<Tab[]>([{ id: 'query-1', label: 'Query', kind: 'query' }])
  const [activeTabId, setActiveTabId] = useState('query-1')
  const [currentDb, setCurrentDb] = useState(session.config.database || '')

  function openTable(obj: DBObject) {
    const existing = tabs.find(t => t.table?.name === obj.name && t.table?.schema === obj.schema)
    if (existing) { setActiveTabId(existing.id); return }
    const id = `table-${obj.schema ?? ''}-${obj.name}`
    setTabs(t => [...t, { id, label: obj.name, kind: 'table', table: obj }])
    setActiveTabId(id)
  }

  function openQuery() {
    const id = `query-${Date.now()}`
    setTabs(t => [...t, { id, label: 'Query', kind: 'query' }])
    setActiveTabId(id)
  }

  function closeTab(id: string) {
    const idx = tabs.findIndex(t => t.id === id)
    setTabs(t => t.filter(x => x.id !== id))
    if (activeTabId === id) {
      const remaining = tabs.filter(x => x.id !== id)
      setActiveTabId(remaining[Math.max(0, idx - 1)]?.id ?? '')
    }
  }

  async function handleDisconnect() {
    // @ts-ignore
    await window.api.disconnect(session.sessionId)
    onDisconnect()
  }

  const activeTab = tabs.find(t => t.id === activeTabId)

  return (
    <div className="flex flex-col h-screen">
      {/* Title bar */}
      <div className="flex items-center justify-between px-4 h-[42px] shrink-0"
        style={{ background: '#141416', borderBottom: '1px solid rgba(255,255,255,0.08)' }}>
        <div className="flex items-center gap-2 min-w-0">
          <div className="w-2 h-2 rounded-full shrink-0" style={{ background: envColor(session.config.environment) }} />
          <span className="text-mb-text text-[13px] font-medium truncate">
            {connectionDisplayName(session.config)}
          </span>
          {currentDb && (
            <>
              <span className="text-mb-dim text-xs">/</span>
              <span className="text-mb-muted text-xs">{currentDb}</span>
            </>
          )}
          {session.serverVersion && (
            <span className="text-mb-dim text-xs ml-1 hidden md:block">· {session.serverVersion.split(' ').slice(0, 2).join(' ')}</span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button className="mb-btn text-xs py-0.5 px-2.5" onClick={openQuery}>+ SQL</button>
          <button className="mb-btn text-xs py-0.5 px-2.5" onClick={handleDisconnect}>Disconnect</button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar */}
        <div className="w-[220px] shrink-0 flex flex-col" style={{ background: '#161618', borderRight: '1px solid rgba(255,255,255,0.08)' }}>
          <ObjectBrowser session={session} onOpenTable={openTable} onDbChange={setCurrentDb} />
        </div>

        {/* Main area */}
        <div className="flex-1 flex flex-col overflow-hidden">
          {/* Tabs */}
          {tabs.length > 0 && (
            <div className="flex items-end gap-0 overflow-x-auto shrink-0"
              style={{ borderBottom: '1px solid rgba(255,255,255,0.08)', background: '#1c1c1e' }}>
              {tabs.map(tab => (
                <div key={tab.id}
                  className="flex items-center gap-1.5 px-3 py-2 cursor-pointer shrink-0 select-none group"
                  style={{
                    borderRight: '1px solid rgba(255,255,255,0.08)',
                    borderBottom: activeTabId === tab.id ? '2px solid #3b82f6' : '2px solid transparent',
                    background: activeTabId === tab.id ? '#1c1c1e' : '#161618',
                    color: activeTabId === tab.id ? '#efefef' : '#888',
                  }}
                  onClick={() => setActiveTabId(tab.id)}>
                  <span className="text-[11px]">{tab.kind === 'table' ? '⊞' : '⚡'}</span>
                  <span className="text-xs whitespace-nowrap max-w-[120px] truncate">{tab.label}</span>
                  {tabs.length > 1 && (
                    <button
                      className="ml-0.5 opacity-0 group-hover:opacity-60 hover:!opacity-100 text-xs leading-none"
                      onClick={e => { e.stopPropagation(); closeTab(tab.id) }}>
                      ×
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}

          {/* Tab content */}
          <div className="flex-1 overflow-hidden">
            {activeTab?.kind === 'table' && activeTab.table ? (
              <DataGrid
                key={activeTab.id}
                session={session}
                table={activeTab.table}
              />
            ) : activeTab?.kind === 'query' ? (
              <SQLEditor
                key={activeTab.id}
                session={session}
                currentDb={currentDb}
              />
            ) : (
              <div className="flex items-center justify-center h-full text-mb-dim text-sm">
                Select a table or open a query
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
