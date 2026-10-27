// Import from Spotify: paste a link to a public playlist or album.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { ImportState } from '@shared/types'
import { Icon } from '../icons'
import { drift, go, importOpenStore, importStore, toast, useStore } from '../state'
import { IconButton, Spinner } from '../ui'
import { plural } from '../util'

function timeLeft(s: ImportState): string | undefined {
  if (s.phase !== 'matching' || !s.matchStart || s.total <= s.processed) return undefined
  const elapsed = (Date.now() - s.matchStart) / 1000
  if (s.processed < 6 || elapsed < 4) return 'estimating time left…'
  const left = (elapsed / s.processed) * (s.total - s.processed)
  if (left < 60) return 'less than a minute left'
  const m = Math.round(left / 60)
  return m < 60 ? `about ${m} min left` : `about ${Math.floor(m / 60)} h ${m % 60} min left`
}

const line = (m: { title: string; artist: string }): string => (m.artist ? `${m.artist} - ${m.title}` : m.title)

export function ImportDialog(): JSX.Element | null {
  const open = useStore(importOpenStore)
  const s = useStore(importStore)
  const [link, setLink] = useState('')
  const input = useRef<HTMLInputElement>(null)
  const [, tick] = useState(0)
  useEffect(() => {
    if (!open) return
    const t = window.setInterval(() => tick((n) => n + 1), 1000)
    const key = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') importOpenStore.set(false)
    }
    window.addEventListener('keydown', key)
    return () => {
      clearInterval(t)
      window.removeEventListener('keydown', key)
    }
  }, [open])
  if (!open) return null

  const close = (): void => importOpenStore.set(false)
  const start = (): void => {
    if (!link.trim()) return
    void drift.startImport(link.trim())
  }
  const busy = s.phase === 'reading' || s.phase === 'matching'

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog import" onMouseDown={(e) => e.stopPropagation()} role="dialog" aria-label="Import from Spotify">
        <div className="import-head">
          <h3>Import from Spotify</h3>
          <IconButton icon="close" label="Close" size={16} onClick={close} />
        </div>

        {(s.phase === 'idle' || s.phase === 'failed') && (
          <>
            <p>Paste a link to a <b>public</b> Spotify playlist or album. You can make the playlist private again once the import is done.</p>
            <form
              className="import-input"
              onSubmit={(e) => {
                e.preventDefault()
                start()
              }}
            >
              <input
                ref={input}
                className="field"
                autoFocus
                value={link}
                placeholder="https://open.spotify.com/playlist/…"
                onChange={(e) => setLink(e.target.value)}
              />
              <button
                type="button"
                className="btn"
                onClick={() =>
                  void navigator.clipboard.readText().then((t) => {
                    setLink(t)
                    input.current?.focus()
                  })
                }
              >
                Paste
              </button>
            </form>
            {s.phase === 'failed' && <div className="set-error">{s.error}</div>}
            <div className="dialog-buttons">
              <button className="btn ghost" onClick={close}>Cancel</button>
              <button className="btn primary" onClick={start} disabled={!link.trim()}>Import</button>
            </div>
            <p className="import-note">Every song is looked up on YouTube Music. Songs that aren’t there come from YouTube uploads, and songs already in your library are reused. The new playlist syncs to your phone.</p>
          </>
        )}

        {busy && (
          <div className="import-progress">
            <div className="import-title">{s.phase === 'reading' ? 'Reading the playlist…' : s.listName}</div>
            <div className="import-bar">
              <div style={{ width: s.total ? `${(s.processed / s.total) * 100}%` : '0%' }} className={s.phase === 'reading' ? 'indeterminate' : ''} />
            </div>
            <div className="set-detail">
              {s.phase === 'reading' ? (
                <><Spinner size={12} /> Opening Spotify’s page</>
              ) : (
                <>Finding songs · {s.processed} of {s.total}{timeLeft(s) ? ` · ${timeLeft(s)}` : ''}</>
              )}
            </div>
            <p className="import-note">You can close this window and keep listening; the import carries on, and songs appear in the playlist as they’re found.</p>
          </div>
        )}

        {s.phase === 'done' && (
          <div className="import-done">
            <div className="import-title">
              <Icon name="check" size={20} /> {s.total - s.missing.length} of {plural(s.total, 'song')} imported
            </div>
            <div className="set-detail">Into “{s.listName}”.{s.foundAgain ? ` ${plural(s.foundAgain, 'more song')} found on the second look.` : ''}</div>
            {s.hitLimit && <div className="set-detail">Only the first 100 songs could be read from Spotify (albums, and playlists Spotify wouldn’t open fully).</div>}
            {s.missing.length > 0 && (
              <>
                <div className="import-missing-head">
                  <b>{plural(s.missing.length, 'song')} not found</b>
                  <span className="import-missing-buttons">
                    <button
                      className="btn small"
                      onClick={() => void navigator.clipboard.writeText(s.missing.map(line).join('\n')).then(() => toast('Copied the missing songs'))}
                    >
                      <Icon name="copy" size={13} /> Copy all
                    </button>
                    <button className="btn small" onClick={() => void drift.retryMissing()} disabled={s.retrying}>
                      {s.retrying ? <Spinner size={12} /> : <Icon name="sync" size={13} />} Look again
                    </button>
                  </span>
                </div>
                <div className="import-missing">
                  {s.missing.map((m, i) => (
                    <div key={i} className="import-missing-row">
                      <span className="n">{i + 1}</span>
                      <span className="t">{m.title}</span>
                      <span className="a">{m.artist}</span>
                    </div>
                  ))}
                </div>
              </>
            )}
            <div className="dialog-buttons">
              <button className="btn ghost" onClick={() => void drift.clearImport()}>Import another</button>
              {s.playlistId && (
                <button
                  className="btn primary"
                  onClick={() => {
                    close()
                    go({ name: 'playlist', id: s.playlistId! })
                  }}
                >
                  Open playlist
                </button>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

/** Small progress pill while an import runs with the window closed. */
export function ImportPill({ className }: { className?: string }): JSX.Element | null {
  const s = useStore(importStore)
  const open = useStore(importOpenStore)
  if (open || (s.phase !== 'reading' && s.phase !== 'matching')) return null
  return (
    <button className={`import-pill ${className ?? ''}`} onClick={() => importOpenStore.set(true)} title="Spotify import">
      <Spinner size={12} /> {s.phase === 'reading' ? 'Reading playlist…' : `Importing ${s.processed}/${s.total}`}
    </button>
  )
}

export function openImport(): void {
  importOpenStore.set(true)
}
