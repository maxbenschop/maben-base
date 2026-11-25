import { useState } from 'react'
import ConnectionsView from './ConnectionsView'
import WorkspaceView from './WorkspaceView'
import type { ActiveSession } from './types'

export default function App() {
  const [session, setSession] = useState<ActiveSession | null>(null)

  if (session) {
    return <WorkspaceView session={session} onDisconnect={() => setSession(null)} />
  }
  return <ConnectionsView onConnect={setSession} />
}
