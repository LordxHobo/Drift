// An import report: the songs that weren't found, with ways to find them (like the phone's notification).
import type { JSX } from 'react'
import type { MissingSong } from '@shared/types'
import { Icon } from '../icons'
import { drift, go, notificationsStore, openNoticeStore, Store, toast, useStore } from '../state'
import { formatTime } from '../util'
import { searchModeStore } from './browse'

/** The report shown (its id). */
export const reportStore = new Store<string | null>(null)

// Clicking Drift's notification in Windows (or macOS, Linux) opens the report.
openNoticeStore.subscribe(() => {
  const id = openNoticeStore.get()
  if (!id) return
  openNoticeStore.set(null)
  reportStore.set(id)
  void drift.markNotificationsRead()
})

const line = (m: MissingSong): string => (m.artist ? `${m.artist} - ${m.title}` : m.title)

export function ReportDialog(): JSX.Element | null {
  const id = useStore(reportStore)
  const n = useStore(notificationsStore).find((x) => x.id === id)
  if (!id || !n) return null
  const close = (): void => reportStore.set(null)
  const find = (m: MissingSong, where: 'music' | 'youtube'): void => {
    searchModeStore.set(where)
    go({ name: 'search', q: `${m.artist} ${m.title}`.trim() })
    close()
  }
  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog report" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>{n.title}</h3>
        <p>{n.detail}</p>
        {n.missing.length > 0 ? (
          <div className="report-list">
            {n.missing.map((m, i) => (
              <div key={`${i}-${m.title}`} className="report-row">
                <div className="replace-text">
                  <div className="replace-title">{m.title}</div>
                  <div className="replace-sub">{[m.artist, m.duration ? formatTime(m.duration) : ''].filter(Boolean).join(' · ')}</div>
                </div>
                <button className="btn small" title="Search YouTube Music" onClick={() => find(m, 'music')}>Search</button>
                <button className="btn small" title="Look for fan uploads on YouTube" onClick={() => find(m, 'youtube')}>Find on YouTube</button>
              </div>
            ))}
          </div>
        ) : (
          <div className="empty small">Everything was found.</div>
        )}
        <div className="dialog-buttons report-buttons">
          <button className="btn ghost danger-text" onClick={() => (void drift.removeNotification(n.id), close())}>Delete</button>
          <span className="spacer" />
          {n.missing.length > 0 && (
            <>
              <button
                className="btn ghost"
                onClick={() => void navigator.clipboard.writeText([n.listName ? `Missing from “${n.listName}”:` : '', ...n.missing.map(line)].filter(Boolean).join('\n')).then(() => toast('Copied the list'))}
              >
                <Icon name="copy" size={14} /> Copy list
              </button>
              <button className="btn ghost" disabled={n.retrying} onClick={() => void drift.retryReport(n.id)}>
                {n.retrying ? 'Looking…' : 'Look for these again'}
              </button>
            </>
          )}
          {n.playlistId && (
            <button className="btn primary" onClick={() => (go({ name: 'playlist', id: n.playlistId! }), close())}>Open playlist</button>
          )}
        </div>
      </div>
    </div>
  )
}
