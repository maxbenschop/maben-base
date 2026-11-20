import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
  // Connection storage
  listConnections: () => ipcRenderer.invoke('connections:list'),
  saveConnection: (config: unknown, password: string) => ipcRenderer.invoke('connections:save', config, password),
  deleteConnection: (id: string) => ipcRenderer.invoke('connections:delete', id),
  getPassword: (id: string) => ipcRenderer.invoke('connections:getPassword', id),
  setPassword: (id: string, pw: string) => ipcRenderer.invoke('connections:setPassword', id, pw),

  // Database operations
  connect: (config: unknown, password: string) => ipcRenderer.invoke('db:connect', config, password),
  disconnect: (sessionId: string) => ipcRenderer.invoke('db:disconnect', sessionId),
  serverVersion: (sessionId: string) => ipcRenderer.invoke('db:serverVersion', sessionId),
  testConnection: (config: unknown, password: string) => ipcRenderer.invoke('db:test', config, password),

  execute: (sessionId: string, sql: string, rowLimit?: number) =>
    ipcRenderer.invoke('db:execute', sessionId, sql, rowLimit),

  databases: (sessionId: string) => ipcRenderer.invoke('db:databases', sessionId),
  useDatabase: (sessionId: string, db: string, config: unknown, password: string) =>
    ipcRenderer.invoke('db:useDatabase', sessionId, db, config, password),
  currentDatabase: (sessionId: string) => ipcRenderer.invoke('db:currentDatabase', sessionId),
  schemas: (sessionId: string) => ipcRenderer.invoke('db:schemas', sessionId),
  objects: (sessionId: string, schema?: string) => ipcRenderer.invoke('db:objects', sessionId, schema),
  columns: (sessionId: string, table: string, schema?: string) =>
    ipcRenderer.invoke('db:columns', sessionId, table, schema),
  fetchPage: (sessionId: string, table: string, schema: string | null, page: number, pageSize: number, sort?: unknown) =>
    ipcRenderer.invoke('db:fetchPage', sessionId, table, schema, page, pageSize, sort),
  saveEdits: (sessionId: string, table: string, schema: string | null, edits: unknown[]) =>
    ipcRenderer.invoke('db:saveEdits', sessionId, table, schema, edits),

  openExternal: (url: string) => ipcRenderer.send('shell:openExternal', url),
}

if (process.contextIsolated) {
  contextBridge.exposeInMainWorld('electron', electronAPI)
  contextBridge.exposeInMainWorld('api', api)
} else {
  // @ts-ignore
  window.electron = electronAPI
  // @ts-ignore
  window.api = api
}

export type API = typeof api
