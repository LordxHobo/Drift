import { contextBridge, ipcRenderer } from 'electron'
import type { DriftApi, DriftEvent } from '@shared/types'
import { apiMethods } from '@shared/types'

const api = Object.fromEntries(
  apiMethods.map((name) => [name, (...args: unknown[]) => ipcRenderer.invoke(`drift:${name}`, ...args)])
) as unknown as DriftApi

contextBridge.exposeInMainWorld('drift', {
  ...api,
  on(event: DriftEvent, listener: (payload: unknown) => void): () => void {
    const handler = (_e: unknown, name: DriftEvent, payload: unknown): void => {
      if (name === event) listener(payload)
    }
    ipcRenderer.on('drift:event', handler)
    return () => ipcRenderer.removeListener('drift:event', handler)
  }
})
