import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import { Icon, Logo } from '../icons'
import { accountStore, connectionsStore, dialogStore, downloadsStore, drift, go, meStore, pairingStore, platformStore, setSettings, settingsStore, updateStore, useStore } from '../state'
import { Avatar, Spinner } from '../ui'
import { accents, musicRed, plural, timeAgo } from '../util'
import { formatBytes } from '../downloads'
import { editProfileStore } from './editProfile'
import { bestQuality } from '../video'
import { showPatchNotes } from './patchNotes'

function Toggle({ on, onChange, label }: { on: boolean; onChange: (v: boolean) => void; label: string }): JSX.Element {
  return (
    <button className={`toggle ${on ? 'on' : ''}`} role="switch" aria-checked={on} aria-label={label} onClick={() => onChange(!on)}>
      <span />
    </button>
  )
}

function Row({ title, detail, children }: { title: string; detail?: string; children: JSX.Element }): JSX.Element {
  return (
    <div className="set-row">
      <div className="set-text">
        <div className="set-title">{title}</div>
        {detail && <div className="set-detail">{detail}</div>}
      </div>
      {children}
    </div>
  )
}

export function SettingsPage(): JSX.Element {
  const s = useStore(settingsStore)
  const platform = useStore(platformStore)
  const [version, setVersion] = useState('')
  useEffect(() => void drift.appInfo().then((i) => setVersion(i.version)), [])

  return (
    <div className="page settings">
      <h1 className="page-title">Settings</h1>

      <section className="set-section">
        <h2>Your phone</h2>
        <LinkPhone />
      </section>

      <section className="set-section">
        <h2>Look</h2>
        <div className="style-cards">
          {(['drift', 'music'] as const).map((style) => (
            <button key={style} className={`style-card ${s.style === style ? 'on' : ''}`} onClick={() => setSettings({ style })}>
              <div className={`style-preview ${style}`}>
                <i />
                <b />
                <em />
              </div>
              <div className="style-name">{style === 'drift' ? 'Drift' : 'Apple Music style'}</div>
            </button>
          ))}
        </div>
        {s.style === 'music' && (
          <Row title="App icon" detail="The icon on the window, taskbar and tray while Drift runs.">
            <div className="icon-choices">
              {(['pink', 'white'] as const).map((k) => (
                <button key={k} className={`icon-choice ${s.musicIcon === k ? 'on' : ''}`} onClick={() => setSettings({ musicIcon: k })}>
                  <IconPreview kind={k} />
                  <span>{k === 'pink' ? 'Pink' : 'White'}</span>
                </button>
              ))}
            </div>
          </Row>
        )}
        <Row title="Appearance">
          <div className="seg">
            {(['device', 'dark', 'light'] as const).map((a) => (
              <button key={a} className={s.appearance === a ? 'on' : ''} onClick={() => setSettings({ appearance: a })}>
                {a === 'device' ? 'Same as computer' : a === 'dark' ? 'Dark' : 'Light'}
              </button>
            ))}
          </div>
        </Row>
        {s.style === 'drift' ? (
          <Row title="Accent color">
            <div className="swatches">
              {accents.map((a, i) => (
                <button
                  key={a.name}
                  className={`swatch ${s.accent === i ? 'on' : ''}`}
                  style={{ background: a.dark }}
                  aria-label={a.name}
                  title={a.name}
                  onClick={() => setSettings({ accent: i })}
                />
              ))}
            </div>
          </Row>
        ) : (
          <Row title="Accent color" detail="The Apple Music style always uses its red.">
            <span className="swatch on static" style={{ background: musicRed }} />
          </Row>
        )}
      </section>

      <section className="set-section">
        <h2>Playback</h2>
        <Row title="Prefer album versions" detail="When a song is a music video, play the album version instead (no intros or skits), like on your phone.">
          <Toggle on={s.preferOfficialAudio} onChange={(v) => setSettings({ preferOfficialAudio: v })} label="Prefer album versions" />
        </Row>
        <Row title="Prefer explicit versions" detail="When a song has a clean (censored) and an explicit version, always play the explicit one, the way the artist made it.">
          <Toggle on={s.preferExplicit} onChange={(v) => setSettings({ preferExplicit: v })} label="Prefer explicit versions" />
        </Row>
        <Row title="Skip non-music parts" detail="Jumps past intros, outros and talking in music videos, using parts marked by the SponsorBlock community.">
          <Toggle on={s.skipNonMusic} onChange={(v) => setSettings({ skipNonMusic: v })} label="Skip non-music parts" />
        </Row>
        <Row title="Show video for podcasts" detail="Episodes play with their video (in the player, or in a small window while you browse). Uses more data. Songs stay audio only.">
          <Toggle on={s.podcastVideo} onChange={(v) => setSettings({ podcastVideo: v })} label="Show video for podcasts" />
        </Row>
        {s.podcastVideo && (
          <Row title="Video quality" detail="The most to use. You can also change it on the video itself.">
            <div className="seg">
              {[360, 480, 720, 1080, bestQuality].map((q) => {
                const v = s.videoQuality || 720
                const on = q === bestQuality ? v > 1080 : v === q || (q === 360 && v < 360)
                return (
                  <button key={q} className={on ? 'on' : ''} onClick={() => setSettings({ videoQuality: q })}>
                    {q === bestQuality ? 'Best' : `${q}p`}
                  </button>
                )
              })}
            </div>
          </Row>
        )}
        <Row title="Skip sponsors in podcasts" detail="Skips sponsor reads, self-promotion and “like and subscribe” reminders the SponsorBlock community has marked.">
          <Toggle on={s.skipSponsors} onChange={(v) => setSettings({ skipSponsors: v })} label="Skip sponsors in podcasts" />
        </Row>
      </section>

      <section className="set-section">
        <h2>Computer</h2>
        {platform !== 'darwin' && (
          <Row title="Keep playing in the tray when closed" detail="Closing the window keeps the music going; Drift stays in the tray (near the clock). Quit from the tray icon.">
            <Toggle on={s.closeToTray} onChange={(v) => setSettings({ closeToTray: v })} label="Keep playing in the tray when closed" />
          </Row>
        )}
        {platform !== 'linux' && (
          <Row title="Open Drift when you sign in">
            <Toggle on={s.openAtLogin} onChange={(v) => setSettings({ openAtLogin: v })} label="Open Drift when you sign in" />
          </Row>
        )}
      </section>

      <section className="set-section">
        <h2>Connections</h2>
        <OrbitSettings />
        <DiscordSettings />
      </section>

      <section className="set-section">
        <h2>Downloads</h2>
        <DownloadSettings />
      </section>

      <section className="set-section">
        <h2>Updates</h2>
        <Updates version={version} />
      </section>

      <section className="set-section">
        <h2>Keyboard</h2>
        <div className="keys">
          <span><kbd>Space</kbd> Play or pause</span>
          <span><kbd>Ctrl</kbd> <kbd>→</kbd> Next song</span>
          <span><kbd>Ctrl</kbd> <kbd>←</kbd> Previous song</span>
          <span><kbd>Ctrl</kbd> <kbd>L</kbd> Search</span>
          <span><kbd>Alt</kbd> <kbd>←</kbd> Back</span>
        </div>
      </section>

      <div className="about">
        <Logo size={18} />
        <button className="link about-version" onClick={showPatchNotes} title="What’s new">
          Drift {version} for {platform === 'win32' ? 'Windows' : platform === 'darwin' ? 'Mac' : 'Linux'} · What’s new
        </button>
      </div>
    </div>
  )
}

function LinkPhone(): JSX.Element {
  const account = useStore(accountStore)
  const pairing = useStore(pairingStore)
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  if (account.linked) {
    return (
      <div className="link-card">
        <div className="link-who">
          <Avatar size={48} />
          <div>
            <div className="set-title">{account.username ?? 'Linked'}</div>
            <div className="set-detail">
              {account.syncing ? 'Syncing…' : account.error ? account.error : account.lastSync ? `Library synced ${timeAgo(account.lastSync)}` : 'Linked with your phone'}
            </div>
          </div>
        </div>
        <p className="set-detail">Playlists, albums, liked songs and followed artists stay the same here and on your phone.</p>
        <ShareActivity />
        <AllowInvites />
        <div className="link-buttons">
          <button className="btn" onClick={() => editProfileStore.set(true)}>
            <Icon name="edit" size={14} /> Edit profile
          </button>
          <button className="btn" onClick={() => void drift.syncNow()} disabled={account.syncing}>
            {account.syncing ? <Spinner size={14} /> : <Icon name="sync" size={14} />} Sync now
          </button>
          <button
            className="btn ghost"
            onClick={() =>
              dialogStore.set({
                kind: 'confirm',
                title: 'Unlink your phone?',
                message: 'Your library stays on this computer, but changes stop syncing. You can link again any time.',
                confirm: 'Unlink',
                danger: true,
                onDone: () => void drift.unlink()
              })
            }
          >
            Unlink
          </button>
        </div>
      </div>
    )
  }

  if (pairing.phase === 'waiting') {
    const left = Math.max(0, Math.round((pairing.expires - now) / 1000))
    return (
      <div className="link-card pairing">
        <ol className="link-steps">
          <li>Open Drift on your iPhone.</li>
          <li>Go to <b>Settings → Link a computer</b>.</li>
          <li>Type this code:</li>
        </ol>
        <div className="pair-code" aria-label={`Code ${pairing.code.split('').join(' ')}`}>{pairing.code}</div>
        <div className="set-detail">
          <Spinner size={12} /> Waiting for your phone · the code works for {Math.floor(left / 60)}:{String(left % 60).padStart(2, '0')}
        </div>
        <button className="btn ghost" onClick={() => void drift.cancelPairing()}>Cancel</button>
      </div>
    )
  }

  return (
    <div className="link-card">
      <div className="link-who">
        <span className="link-icon"><Icon name="phone" size={26} /></span>
        <div>
          <div className="set-title">Use your phone’s library here</div>
          <div className="set-detail">Link this computer to your Drift profile to get your playlists, albums, liked songs and followed artists, and keep them in sync.</div>
        </div>
      </div>
      {pairing.phase === 'failed' && <div className="set-error">{pairing.message}</div>}
      {pairing.phase === 'done' && <div className="set-ok">Linked.</div>}
      <div className="link-buttons">
        <button className="btn primary" onClick={() => void drift.startPairing()} disabled={pairing.phase === 'starting' || pairing.phase === 'linking'}>
          {pairing.phase === 'starting' || pairing.phase === 'linking' ? <Spinner size={14} /> : null}
          {pairing.phase === 'linking' ? 'Linking…' : 'Link your phone'}
        </button>
      </div>
      <p className="set-detail small">You need a Drift profile on your phone. The link is encrypted end to end between your phone and this computer.</p>
    </div>
  )
}

function Updates({ version }: { version: string }): JSX.Element {
  const u = useStore(updateStore)
  const status =
    u.phase === 'checking' ? 'Checking…'
    : u.phase === 'none' ? 'Drift is up to date.'
    : u.phase === 'downloading' ? `Downloading Drift ${u.version ?? ''}… ${u.percent ?? 0}%`
    : u.phase === 'ready' ? `Drift ${u.version} is ready. It installs by itself once nothing has played for a minute, or restart now.`
    : u.phase === 'available' ? `Drift ${u.version} is out. Download it and replace this version.`
    : u.phase === 'error' ? `Couldn’t check for updates: ${u.message ?? 'unknown error'}`
    : u.phase === 'dev' ? u.message ?? ''
    : 'New versions download in the background and install by themselves while nothing is playing.'
  return (
    <Row title={`Drift ${version}`} detail={status}>
      {u.phase === 'ready' ? (
        <button className="btn primary" onClick={() => void drift.installUpdate()}>Restart now</button>
      ) : u.phase === 'available' && u.url ? (
        <button className="btn primary" onClick={() => void drift.openExternal(u.url!)}>Download</button>
      ) : (
        <button className="btn" onClick={() => void drift.checkForUpdates()} disabled={u.phase === 'checking' || u.phase === 'downloading' || u.phase === 'dev'}>
          {u.phase === 'checking' ? <Spinner size={14} /> : <Icon name="sync" size={14} />} Check now
        </button>
      )}
    </Row>
  )
}

function DownloadSettings(): JSX.Element {
  const d = useStore(downloadsStore)
  return (
    <>
      <Row title="Storage used" detail={`${plural(d.done.length, 'song')} on this computer. Downloads aren’t synced; your phone keeps its own.`}>
        <span className="set-value">{formatBytes(d.bytes)}</span>
      </Row>
      <Row title="Folder" detail={d.folder}>
        <div className="link-buttons tight">
          <button className="btn" onClick={() => go({ name: 'collection', kind: 'downloaded' })}>Show songs</button>
          <button className="btn" onClick={() => void drift.openDownloadsFolder()}>Open folder</button>
        </div>
      </Row>
      <Row title="Remove all downloads" detail="Songs keep playing by streaming.">
        <button
          className="btn ghost danger-text"
          disabled={!d.done.length && !d.queued.length && !d.active.length}
          onClick={() =>
            dialogStore.set({
              kind: 'confirm',
              title: 'Remove all downloads?',
              message: `${plural(d.done.length, 'song')} (${formatBytes(d.bytes)}) are deleted from this computer, and playlists stop downloading new songs.`,
              confirm: 'Remove all',
              danger: true,
              onDone: () => void drift.removeAllDownloads()
            })
          }
        >
          Remove all
        </button>
      </Row>
    </>
  )
}

function ShareActivity(): JSX.Element | null {
  const me = useStore(meStore)
  if (!me) return null
  return (
    <div className="set-row in-card">
      <div className="set-text">
        <div className="set-title">Share what I listen to</div>
        <div className="set-detail">Friends who follow you see what’s playing. Same setting as on your phone.</div>
      </div>
      <Toggle
        on={me.shareActivity}
        label="Share what I listen to"
        onChange={(v) => {
          meStore.set({ ...me, shareActivity: v })
          void drift.setShareActivity(v)
        }}
      />
    </div>
  )
}

function AllowInvites(): JSX.Element | null {
  const me = useStore(meStore)
  if (!me) return null
  return (
    <div className="set-row in-card">
      <div className="set-text">
        <div className="set-title">Listen Together invites</div>
        <div className="set-detail">Friends who follow you back can invite you to listen together. Same setting as on your phone.</div>
      </div>
      <Toggle
        on={me.allowInvites !== false}
        label="Listen Together invites"
        onChange={(v) => {
          meStore.set({ ...me, allowInvites: v })
          void drift.setAllowInvites(v)
        }}
      />
    </div>
  )
}

function StatusLine({ state, message }: { state: string; message?: string }): JSX.Element | null {
  if (state === 'off' || !message) return null
  return <div className={`conn-status ${state}`}>{state === 'waiting' ? <Spinner size={11} /> : <span className="dot" />} {message}</div>
}

function OrbitSettings(): JSX.Element {
  const s = useStore(settingsStore)
  const c = useStore(connectionsStore).orbit
  const [url, setUrl] = useState(s.orbitUrl)
  const [token, setToken] = useState('')
  useEffect(() => setUrl(s.orbitUrl), [s.orbitUrl])
  return (
    <div className="conn-card">
      <Row title="Orbit" detail="Show what you’re listening to on your Orbit server, next to your name.">
        <Toggle on={s.orbitEnabled} onChange={(v) => setSettings({ orbitEnabled: v })} label="Share with Orbit" />
      </Row>
      {s.orbitEnabled && (
        <div className="conn-fields">
          <label>
            <span>Server address</span>
            <input className="field" value={url} placeholder="https://orbit.example.com" onChange={(e) => setUrl(e.target.value)} onBlur={() => url !== s.orbitUrl && setSettings({ orbitUrl: url.trim() })} />
          </label>
          <label>
            <span>Token {c.hasToken && <em>(saved)</em>}</span>
            <input
              className="field"
              type="password"
              value={token}
              placeholder={c.hasToken ? '••••••••  (paste a new one to replace it)' : 'Paste the token from Orbit'}
              onChange={(e) => setToken(e.target.value)}
              onBlur={() => {
                if (token.trim()) {
                  void drift.setOrbitToken(token.trim())
                  setToken('')
                }
              }}
            />
          </label>
          <div className="link-buttons tight">
            <button
              className="btn"
              onClick={() => {
                if (url !== s.orbitUrl) setSettings({ orbitUrl: url.trim() })
                const saving = token.trim() ? drift.setOrbitToken(token.trim()) : Promise.resolve()
                setToken('')
                void saving.then(() => drift.testOrbit())
              }}
            >
              Test connection
            </button>
            {c.hasToken && <button className="btn ghost" onClick={() => void drift.setOrbitToken('')}>Remove token</button>}
          </div>
          <StatusLine state={c.state} message={c.message} />
        </div>
      )}
    </div>
  )
}

function DiscordSettings(): JSX.Element {
  const s = useStore(settingsStore)
  const c = useStore(connectionsStore).discord
  const [id, setId] = useState(s.discordAppId)
  useEffect(() => setId(s.discordAppId), [s.discordAppId])
  return (
    <div className="conn-card">
      <Row title="Discord" detail="“Listening to” on your Discord profile, through the Discord app on this computer.">
        <Toggle on={s.discordEnabled} onChange={(v) => setSettings({ discordEnabled: v })} label="Show on Discord" />
      </Row>
      {s.discordEnabled && (
        <div className="conn-fields">
          <label>
            <span>Application ID</span>
            <input className="field" value={id} inputMode="numeric" placeholder="e.g. 1234567890123456789" onChange={(e) => setId(e.target.value.replace(/\D/g, ''))} onBlur={() => id !== s.discordAppId && setSettings({ discordAppId: id })} />
          </label>
          <p className="set-detail">
            Discord needs an application to show the status under. Make one at{' '}
            <button className="link" onClick={() => void drift.openExternal('https://discord.com/developers/applications')}>discord.com/developers</button>{' '}
            (New Application, name it “Drift”, which is what Discord shows), then copy its Application ID here.
          </p>
          <StatusLine state={c.state} message={c.message} />
        </div>
      )}
    </div>
  )
}

/** A small drawing of an Apple Music style icon: Drift's four bars, white on pink or pink on white. */
function IconPreview({ kind }: { kind: 'pink' | 'white' }): JSX.Element {
  const bars = [[266, 301, 721], [398, 371, 651], [530, 251, 771], [662, 331, 691]]
  const id = `icon-grad-${kind}`
  return (
    <svg viewBox="0 0 1024 1024" width="52" height="52" className="icon-preview" aria-hidden="true">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ff5587" />
          <stop offset="1" stopColor="#ff0046" />
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" rx="230" fill={kind === 'pink' ? `url(#${id})` : '#fff'} />
      {bars.map(([x, top, bottom]) => (
        <rect key={x} x={x} y={top} width="96" height={bottom - top} rx="48" fill={kind === 'pink' ? '#fff' : `url(#${id})`} />
      ))}
    </svg>
  )
}
