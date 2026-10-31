// Listening stats: how much you listened, to what, and when (every device you use Drift on).
import { useEffect, useMemo, useState } from 'react'
import type { JSX } from 'react'
import type { Track } from '@shared/types'
import type { PlayRecord, StatsSpan, StatsSummary } from '@shared/stats'
import { statsSpans, summarize } from '@shared/stats'
import { accountStore, drift, openMenu, readLocal, useStore, writeLocal } from '../state'
import { Art, BigPlay, Spinner, trackMenu } from '../ui'
import { playList } from '../player'
import { plural } from '../util'

const toTrack = (p: PlayRecord): Track => ({ id: p.id, title: p.title, artist: p.artist, artworkURL: p.art || undefined })

export function StatsPage(): JSX.Element {
  const [span, setSpan] = useState<StatsSpan>(() => readLocal('statsSpan', 'month'))
  const [data, setData] = useState<{ plays: PlayRecord[]; devices: number } | null>(null)
  const account = useStore(accountStore)
  useEffect(() => writeLocal('statsSpan', span), [span])
  useEffect(() => {
    void drift.listeningHistory().then(setData).catch(() => setData({ plays: [], devices: 1 }))
  }, [])
  const s = useMemo(() => (data ? summarize(data.plays, span) : null), [data, span])

  const since = data?.plays.length ? new Date(Math.min(...data.plays.map((p) => p.at)) * 1000) : null
  const notes = ['Songs count once you’ve listened for 30 seconds.']
  if (since) notes.push(`Counting since ${since.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })}.`)
  if (data && data.devices > 1) notes.push(`Adds up ${data.devices} devices.`)
  else if (!account.linked) notes.push('Link your phone in Settings to add up what you play there too.')

  return (
    <div className="page stats-page">
      <div className="page-title-row">
        <h1 className="page-title">Listening stats</h1>
        <div className="chips" role="tablist" aria-label="Period">
          {statsSpans.map((x) => (
            <button key={x.id} role="tab" aria-selected={span === x.id} className={`chip ${span === x.id ? 'on' : ''}`} onClick={() => setSpan(x.id)}>
              {x.label}
            </button>
          ))}
        </div>
      </div>
      {!s ? (
        <div className="empty"><Spinner size={22} /></div>
      ) : !s.plays.length ? (
        <div className="empty">
          {data?.plays.length ? 'Nothing in this period. Pick a longer one to see more.' : 'Nothing yet. Play some music: songs show up here once you’ve listened for 30 seconds.'}
        </div>
      ) : (
        <>
          <div className="stats-totals">
            <Total value={s.minutes} label="minutes" />
            <Total value={s.plays.length} label={s.plays.length === 1 ? 'play' : 'plays'} />
            <Total value={s.artistCount} label={s.artistCount === 1 ? 'artist' : 'artists'} />
          </div>
          <MinutesChart s={s} />
          <div className="stats-columns">
            <section className="stats-col">
              <div className="stats-col-head">
                <h2>Top artists</h2>
              </div>
              <ol className="stats-list">
                {s.topArtists.map((a, i) => (
                  <li key={a.name} className="stats-row">
                    <span className="stats-rank">{i + 1}</span>
                    <Art src={a.art ?? undefined} seed={a.name} size={44} round />
                    <span className="stats-text">
                      <span className="stats-name">{a.name}</span>
                      <span className="stats-sub">{a.minutes.toLocaleString()} min · {plural(a.plays, 'play')}</span>
                    </span>
                  </li>
                ))}
              </ol>
            </section>
            <section className="stats-col">
              <div className="stats-col-head">
                <h2>Top songs</h2>
                <BigPlay label="Play your top songs" onClick={() => playList(s.topSongs.map((x) => toTrack(x.play)), 0, { kind: 'queue', name: 'Your top songs' }, { shuffle: false })} />
              </div>
              <ol className="stats-list">
                {s.topSongs.map((x, i) => {
                  const t = toTrack(x.play)
                  return (
                    <li key={t.id}>
                      <button
                        className="stats-row song"
                        onClick={() => playList(s.topSongs.map((y) => toTrack(y.play)), i, { kind: 'queue', name: 'Your top songs' }, { shuffle: false })}
                        onContextMenu={(e) => openMenu(e, trackMenu(t))}
                      >
                        <span className="stats-rank">{i + 1}</span>
                        <Art src={t.artworkURL ?? undefined} seed={t.id} size={44} radius={4} />
                        <span className="stats-text">
                          <span className="stats-name">{t.title}</span>
                          <span className="stats-sub">{t.artist}</span>
                        </span>
                        <span className="stats-count">{plural(x.plays, 'play')}</span>
                      </button>
                    </li>
                  )
                })}
              </ol>
            </section>
          </div>
        </>
      )}
      <p className="stats-note">{notes.join(' ')}</p>
    </div>
  )
}

function Total({ value, label }: { value: number; label: string }): JSX.Element {
  return (
    <div className="stats-total">
      <span className="stats-value">{value.toLocaleString()}</span>
      <span className="stats-label">{label}</span>
    </div>
  )
}

/** Minutes per day, week or month, as bars. */
function MinutesChart({ s }: { s: StatsSummary }): JSX.Element {
  const max = Math.max(1, ...s.buckets.map((b) => b.minutes))
  const nice = niceMax(max)
  const fmt = (t: number): string =>
    new Date(t).toLocaleDateString(undefined, s.unit === 'month' ? { month: 'short' } : { day: 'numeric', month: 'short' })
  const every = Math.max(1, Math.ceil(s.buckets.length / 6))
  const label = s.unit === 'day' ? 'per day' : s.unit === 'week' ? 'per week' : 'per month'
  return (
    <figure className="stats-chart">
      <figcaption>Minutes {label}</figcaption>
      <div className="stats-plot">
        <div className="stats-axis" aria-hidden="true">
          <span>{nice.toLocaleString()}</span>
          <span>{(nice / 2).toLocaleString(undefined, { maximumFractionDigits: 1 })}</span>
          <span>0</span>
        </div>
        <div className="stats-bars">
          {s.buckets.map((b, i) => (
            <div key={b.start} className="stats-bar-cell" title={`${fmt(b.start)}: ${Math.round(b.minutes).toLocaleString()} min`}>
              <div className="stats-bar" style={{ height: `${(b.minutes / nice) * 100}%` }} />
              <span className="stats-tick">{i % every === 0 ? fmt(b.start) : ''}</span>
            </div>
          ))}
        </div>
      </div>
    </figure>
  )
}

function niceMax(n: number): number {
  const step = Math.pow(10, Math.floor(Math.log10(n)))
  for (const m of [1, 2, 2.5, 5, 10]) if (m * step >= n) return m * step
  return 10 * step
}
