import type { DriftApi, DriftEvent } from '../shared/types'

declare global {
  interface Window {
    drift: DriftApi & { on(event: DriftEvent, listener: (payload: any) => void): () => void }
  }
}
export {}
